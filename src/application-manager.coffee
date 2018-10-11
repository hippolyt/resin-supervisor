Promise = require 'bluebird'
_ = require 'lodash'
EventEmitter = require 'events'
express = require 'express'
bodyParser = require 'body-parser'
fs = Promise.promisifyAll(require('fs'))
path = require 'path'

constants = require './lib/constants'

Docker = require './lib/docker-utils'
{ LocalModeManager } = require './local-mode'
updateLock = require './lib/update-lock'
{ checkTruthy, checkInt, checkString } = require './lib/validation'
{ NotFoundError } = require './lib/errors'

ServiceManager = require './compose/service-manager'
{ Service } = require './compose/service'
Images = require './compose/images'
{ NetworkManager } = require './compose/network-manager'
{ Network } = require './compose/network'
Volumes = require './compose/volumes'

Proxyvisor = require './proxyvisor'

{ createV1Api } = require './device-api/v1'
{ createV2Api } = require './device-api/v2'
{ serviceAction } = require './device-api/common'

# TODO: move this to an Image class?
imageForService = (service) ->
	return {
		name: service.imageName
		appId: service.appId
		serviceId: service.serviceId
		serviceName: service.serviceName
		imageId: service.imageId
		releaseId: service.releaseId
		dependent: 0
	}

fetchAction = (service) ->
	return {
		action: 'fetch'
		image: imageForService(service)
		serviceId: service.serviceId
	}

pathExistsOnHost = (p) ->
	fs.statAsync(path.join(constants.rootMountPoint, p))
	.return(true)
	.catchReturn(false)

# TODO: implement additional v2 endpoints
# Some v1 endpoins only work for single-container apps as they assume the app has a single service.
createApplicationManagerRouter = (applications) ->
	router = express.Router()
	router.use(bodyParser.urlencoded(extended: true))
	router.use(bodyParser.json())

	createV1Api(router, applications)
	createV2Api(router, applications)

	router.use(applications.proxyvisor.router)

	return router

module.exports = class ApplicationManager extends EventEmitter
	constructor: ({ @logger, @config, @db, @eventTracker, @deviceState }) ->
		@docker = new Docker()
		@images = new Images({ @docker, @logger, @db })
		@services = new ServiceManager({ @docker, @logger, @images, @config })
		@networks = new NetworkManager({ @docker, @logger })
		@volumes = new Volumes({ @docker, @logger })
		@proxyvisor = new Proxyvisor({ @config, @logger, @db, @docker, @images, applications: this })
		@localModeManager = new LocalModeManager(@config, @docker, @logger, @db)
		@timeSpentFetching = 0
		@fetchesInProgress = 0
		@_targetVolatilePerImageId = {}
		@_containerStarted = {}
		@actionExecutors = {
			stop: (step, { force = false, skipLock = false } = {}) =>
				@_lockingIfNecessary step.current.appId, { force, skipLock: skipLock or step.options?.skipLock }, =>
					wait = step.options?.wait ? false
					@services.kill(step.current, { removeContainer: false, wait })
					.then =>
						delete @_containerStarted[step.current.containerId]
			kill: (step, { force = false, skipLock = false } = {}) =>
				@_lockingIfNecessary step.current.appId, { force, skipLock: skipLock or step.options?.skipLock }, =>
					@services.kill(step.current)
					.then =>
						delete @_containerStarted[step.current.containerId]
						if step.options?.removeImage
							@images.removeByDockerId(step.current.config.image)
			remove: (step) =>
				# Only called for dead containers, so no need to take locks or anything
				@services.remove(step.current)
			updateMetadata: (step, { force = false, skipLock = false } = {}) =>
				skipLock or= checkTruthy(step.current.config.labels['io.resin.legacy-container'])
				@_lockingIfNecessary step.current.appId, { force, skipLock: skipLock or step.options?.skipLock }, =>
					@services.updateMetadata(step.current, step.target)
			restart: (step, { force = false, skipLock = false } = {}) =>
				@_lockingIfNecessary step.current.appId, { force, skipLock: skipLock or step.options?.skipLock }, =>
					@services.kill(step.current, { wait: true })
					.then =>
						delete @_containerStarted[step.current.containerId]
					.then =>
						@services.start(step.target)
					.then (container) =>
						@_containerStarted[container.id] = true
			stopAll: (step, { force = false, skipLock = false } = {}) =>
				@stopAll({ force, skipLock })
			start: (step) =>
				@services.start(step.target)
				.then (container) =>
					@_containerStarted[container.id] = true
			updateCommit: (step) =>
				@config.set({ currentCommit: step.target })
			handover: (step, { force = false, skipLock = false } = {}) =>
				@_lockingIfNecessary step.current.appId, { force, skipLock: skipLock or step.options?.skipLock }, =>
					@services.handover(step.current, step.target)
			fetch: (step) =>
				startTime = process.hrtime()
				@fetchesInProgress += 1
				Promise.join(
					@config.get('fetchOptions')
					@images.getAvailable()
					(opts, availableImages) =>
						opts.deltaSource = @bestDeltaSource(step.image, availableImages)
						@images.triggerFetch step.image, opts, (success) =>
							@fetchesInProgress -= 1
							elapsed = process.hrtime(startTime)
							elapsedMs = elapsed[0] * 1000 + elapsed[1] / 1e6
							@timeSpentFetching += elapsedMs
							if success
								# update_downloaded is true if *any* image has been downloaded,
								# and it's relevant mostly for the legacy GET /v1/device endpoint
								# that assumes a single-container app
								@reportCurrentState(update_downloaded: true)
				)
			removeImage: (step) =>
				@images.remove(step.image)
			saveImage: (step) =>
				@images.save(step.image)
			cleanup: (step) =>
				@config.get('localMode').then (localMode) ->
					if !checkTruthy(localMode)
						@images.cleanup()
			createNetworkOrVolume: (step) =>
				if step.model is 'network'
					# TODO: These step targets should be the actual compose objects,
					# rather than recreating them
					Network.fromComposeObject({ @docker, @logger },
						step.target.name,
						step.appId,
						step.target.config
					).create()
				else
					@volumes.create(step.target)
			removeNetworkOrVolume: (step) =>
				if step.model is 'network'
					Network.fromComposeObject({ @docker, @logger },
						step.current.name,
						step.appId,
						step.current.config
					).remove()
				else
					@volumes.remove(step.current)
			ensureSupervisorNetwork: =>
				@networks.ensureSupervisorNetwork()
		}
		@validActions = _.keys(@actionExecutors).concat(@proxyvisor.validActions)
		@router = createApplicationManagerRouter(this)
		@images.on('change', @reportCurrentState)
		@services.on('change', @reportCurrentState)

	serviceAction: serviceAction
	imageForService: imageForService
	fetchAction: fetchAction

	reportCurrentState: (data) =>
		@emit('change', data)

	init: =>
		@images.cleanupDatabase()
		.then =>
			@localModeManager.init()
		.then =>
			@services.attachToRunning()
		.then =>
			@services.listenToEvents()

	# Returns the status of applications and their services
	getStatus: =>
		@config.get('localMode').then (localMode) =>
			@_getStatus(localMode)

	_getStatus: (localMode) =>
		Promise.join(
			@services.getStatus()
			@images.getStatus(localMode)
			@config.get('currentCommit')
			@db.models('app').select([ 'appId', 'releaseId', 'commit' ])
			(services, images, currentCommit, targetApps) ->
				apps = {}
				dependent = {}
				releaseId = null
				creationTimesAndReleases = {}
				# We iterate over the current running services and add them to the current state
				# of the app they belong to.
				for service in services
					appId = service.appId
					apps[appId] ?= {}
					creationTimesAndReleases[appId] = {}
					apps[appId].services ?= {}
					# We only send commit if all services have the same release, and it matches the target release
					if !releaseId?
						releaseId = service.releaseId
					else if releaseId != service.releaseId
						releaseId = false
					if !apps[appId].services[service.imageId]?
						apps[appId].services[service.imageId] = _.pick(service, [ 'status', 'releaseId' ])
						creationTimesAndReleases[appId][service.imageId] = _.pick(service, [ 'createdAt', 'releaseId' ])
						apps[appId].services[service.imageId].download_progress = null
					else
						# There's two containers with the same imageId, so this has to be a handover
						apps[appId].services[service.imageId].releaseId = _.minBy([ creationTimesAndReleases[appId][service.imageId], service ], 'createdAt').releaseId
						apps[appId].services[service.imageId].status = 'Handing over'

				for image in images
					appId = image.appId
					if !image.dependent
						apps[appId] ?= {}
						apps[appId].services ?= {}
						if !apps[appId].services[image.imageId]?
							apps[appId].services[image.imageId] = _.pick(image, [ 'status', 'releaseId' ])
							apps[appId].services[image.imageId].download_progress = image.downloadProgress
					else if image.imageId?
						dependent[appId] ?= {}
						dependent[appId].images ?= {}
						dependent[appId].images[image.imageId] = _.pick(image, [ 'status' ])
						dependent[appId].images[image.imageId].download_progress = image.downloadProgress
					else
						console.log('Ignoring legacy dependent image', image)

				obj = { local: apps, dependent }
				obj.commit = currentCommit
				return obj
		)

	getDependentState: =>
		@proxyvisor.getCurrentStates()

	_buildApps: (services, networks, volumes, currentCommit) ->
		apps = {}

		# We iterate over the current running services and add them to the current state
		# of the app they belong to.
		for service in services
			appId = service.appId
			apps[appId] ?= { appId, services: [], volumes: {}, networks: {} }
			apps[appId].services.push(service)

		for network in networks
			appId = network.appId
			apps[appId] ?= { appId, services: [], volumes: {}, networks: {} }
			apps[appId].networks[network.name] = network.config

		for volume in volumes
			appId = volume.appId
			apps[appId] ?= { appId, services: [], volumes: {}, networks: {} }
			apps[appId].volumes[volume.name] = volume.config

		# multi-app warning!
		# This is just wrong on every level
		_.each apps, (app) ->
			app.commit = currentCommit

		return apps

	getCurrentForComparison: =>
		Promise.join(
			@services.getAll()
			@networks.getAll()
			@volumes.getAll()
			@config.get('currentCommit')
			@_buildApps
		)

	getCurrentApp: (appId) =>
		Promise.join(
			@services.getAllByAppId(appId)
			@networks.getAllByAppId(appId)
			@volumes.getAllByAppId(appId)
			@config.get('currentCommit')
			@_buildApps
		).get(appId)

	getTargetApp: (appId) =>
		@config.get('apiEndpoint').then (endpoint = '') ->
			@db.models('app').where({ appId, source: endpoint }).select()
		.then ([ app ]) =>
			if !app?
				return
			@normaliseAndExtendAppFromDB(app)

	# Compares current and target services and returns a list of service pairs to be updated/removed/installed.
	# The returned list is an array of objects where the "current" and "target" properties define the update pair, and either can be null
	# (in the case of an install or removal).
	compareServicesForUpdate: (currentServices, targetServices) =>
		removePairs = []
		installPairs = []
		updatePairs = []
		targetServiceIds = _.map(targetServices, 'serviceId')
		currentServiceIds = _.uniq(_.map(currentServices, 'serviceId'))

		toBeRemoved = _.difference(currentServiceIds, targetServiceIds)
		for serviceId in toBeRemoved
			servicesToRemove = _.filter(currentServices, { serviceId })
			for service in servicesToRemove
				removePairs.push({
					current: service
					target: null
					serviceId
				})

		toBeInstalled = _.difference(targetServiceIds, currentServiceIds)
		for serviceId in toBeInstalled
			serviceToInstall = _.find(targetServices, { serviceId })
			if serviceToInstall?
				installPairs.push({
					current: null
					target: serviceToInstall
					serviceId
				})

		toBeMaybeUpdated = _.intersection(targetServiceIds, currentServiceIds)
		currentServicesPerId = {}
		targetServicesPerId = _.keyBy(targetServices, 'serviceId')
		for serviceId in toBeMaybeUpdated
			currentServiceContainers = _.filter(currentServices, { serviceId })
			if currentServiceContainers.length > 1
				currentServicesPerId[serviceId] = _.maxBy(currentServiceContainers, 'createdAt')

				# All but the latest container for this service are spurious and should be removed
				for service in _.without(currentServiceContainers, currentServicesPerId[serviceId])
					removePairs.push({
						current: service
						target: null
						serviceId
					})
			else
				currentServicesPerId[serviceId] = currentServiceContainers[0]

		# Returns true if a service matches its target except it should be running and it is not, but we've
		# already started it before. In this case it means it just exited so we don't want to start it again.
		alreadyStarted = (serviceId) =>
			return (
				currentServicesPerId[serviceId].isEqualExceptForRunningState(targetServicesPerId[serviceId]) and
				targetServicesPerId[serviceId].config.running  and
				@_containerStarted[currentServicesPerId[serviceId].containerId]
			)

		needUpdate = _.filter toBeMaybeUpdated, (serviceId) ->
			!currentServicesPerId[serviceId].isEqual(targetServicesPerId[serviceId]) and !alreadyStarted(serviceId)

		for serviceId in needUpdate
			updatePairs.push({
				current: currentServicesPerId[serviceId]
				target: targetServicesPerId[serviceId]
				serviceId
			})

		return { removePairs, installPairs, updatePairs }

	_compareNetworksOrVolumesForUpdate: (model, { current, target }, appId) ->
		outputPairs = []
		currentNames = _.keys(current)
		targetNames = _.keys(target)
		toBeRemoved = _.difference(currentNames, targetNames)
		for name in toBeRemoved
			outputPairs.push({
				current: {
					name
					appId
					config: current[name]
				}
				target: null
			})
		toBeInstalled = _.difference(targetNames, currentNames)
		for name in toBeInstalled
			outputPairs.push({
				current: null
				target: {
					name
					appId
					config: target[name]
				}
			})
		toBeUpdated = _.filter _.intersection(targetNames, currentNames), (name) =>
			# While we're in this in-between state of a network-manager, but not
			# a volume-manager, we'll have to inspect the object to detect a
			# network-manager
			if model instanceof NetworkManager
				opts = docker: @docker, logger: @logger
				currentNet = Network.fromComposeObject(
					opts,
					name,
					appId,
					current[name]
				)
				targetNet = Network.fromComposeObject(
					opts,
					name,
					appId,
					target[name]
				)
				return !currentNet.isEqualConfig(targetNet)
			else
				return !model.isEqualConfig(current[name], target[name])
		for name in toBeUpdated
			outputPairs.push({
				current: {
					name
					appId
					config: current[name]
				}
				target: {
					name
					appId
					config: target[name]
				}
			})
		return outputPairs

	compareNetworksForUpdate: ({ current, target }, appId) =>
		@_compareNetworksOrVolumesForUpdate(@networks, { current, target }, appId)

	compareVolumesForUpdate: ({ current, target }, appId) =>
		@_compareNetworksOrVolumesForUpdate(@volumes, { current, target }, appId)

	# Checks if a service is using a network or volume that is about to be updated
	_hasCurrentNetworksOrVolumes: (service, networkPairs, volumePairs) ->
		if !service?
			return false
		hasNetwork = _.some networkPairs, (pair) ->
			"#{service.appId}_#{pair.current?.name}" == service.networkMode
		if hasNetwork
			return true
		hasVolume = _.some service.volumes, (volume) ->
			name = _.split(volume, ':')[0]
			_.some volumePairs, (pair) ->
				"#{service.appId}_#{pair.current?.name}" == name
		return hasVolume

	# TODO: account for volumes-from, networks-from, links, etc
	# TODO: support networks instead of only networkMode
	_dependenciesMetForServiceStart: (target, networkPairs, volumePairs, pendingPairs) ->
		# for dependsOn, check no install or update pairs have that service
		dependencyUnmet = _.some target.dependsOn, (dependency) ->
			_.some(pendingPairs, (pair) -> pair.target?.serviceName == dependency)
		if dependencyUnmet
			return false
		# for networks and volumes, check no network pairs have that volume name
		if _.some(networkPairs, (pair) -> "#{target.appId}_#{pair.target?.name}" == target.networkMode)
			return false
		volumeUnmet = _.some target.volumes, (volumeDefinition) ->
			[ sourceName, destName ] = volumeDefinition.split(':')
			if !destName? # If this is not a named volume, ignore it
				return false
			return _.some(volumePairs, (pair) -> "#{target.appId}_#{pair.target?.name}" == sourceName)
		return !volumeUnmet

	# Unless the update strategy requires an early kill (i.e. kill-then-download, delete-then-download), we only want
	# to kill a service once the images for the services it depends on have been downloaded, so as to minimize
	# downtime (but not block the killing too much, potentially causing a deadlock)
	_dependenciesMetForServiceKill: (target, targetApp, availableImages) =>
		if target.dependsOn?
			for dependency in target.dependsOn
				dependencyService = _.find(targetApp.services, serviceName: dependency)
				if !_.some(availableImages, (image) => image.dockerImageId == dependencyService.image or @images.isSameImage(image, { name: dependencyService.imageName }))
					return false
		return true

	_nextStepsForNetworkOrVolume: ({ current, target }, currentApp, changingPairs, dependencyComparisonFn, model) ->
		# Check none of the currentApp.services use this network or volume
		if current?
			dependencies = _.filter currentApp.services, (service) ->
				dependencyComparisonFn(service, current)
			if _.isEmpty(dependencies)
				return [{ action: 'removeNetworkOrVolume', model, current }]
			else
				# If the current update doesn't require killing the services that use this network/volume,
				# we have to kill them before removing the network/volume (e.g. when we're only updating the network config)
				steps = []
				for dependency in dependencies
					if dependency.status != 'Stopping' and !_.some(changingPairs, serviceId: dependency.serviceId)
						steps.push(serviceAction('kill', dependency.serviceId, dependency))
				return steps
		else if target?
			return [{ action: 'createNetworkOrVolume', model, target }]

	_nextStepsForNetwork: ({ current, target }, currentApp, changingPairs) =>
		dependencyComparisonFn = (service, current) ->
			service.config.networkMode == "#{service.appId}_#{current?.name}"

		@_nextStepsForNetworkOrVolume({ current, target }, currentApp, changingPairs, dependencyComparisonFn, 'network')

	_nextStepsForVolume: ({ current, target }, currentApp, changingPairs) ->
		# Check none of the currentApp.services use this network or volume
		dependencyComparisonFn = (service, current) ->
			_.some service.config.volumes, (volumeDefinition) ->
				[ sourceName, destName ] = volumeDefinition.split(':')
				destName? and sourceName == "#{service.appId}_#{current?.name}"
		@_nextStepsForNetworkOrVolume({ current, target }, currentApp, changingPairs, dependencyComparisonFn, 'volume')

	# Infers steps that do not require creating a new container
	_updateContainerStep: (current, target) ->
		if current.releaseId != target.releaseId or current.imageId != target.imageId
			return serviceAction('updateMetadata', target.serviceId, current, target)
		else if target.config.running
			return serviceAction('start', target.serviceId, current, target)
		else
			return serviceAction('stop', target.serviceId, current, target)

	_fetchOrStartStep: (current, target, needsDownload, dependenciesMetForStart) ->
		if needsDownload
			return fetchAction(target)
		else if dependenciesMetForStart()
			return serviceAction('start', target.serviceId, current, target)
		else
			return null

	_strategySteps: {
		'download-then-kill': (current, target, needsDownload, dependenciesMetForStart, dependenciesMetForKill) ->
			if needsDownload
				return fetchAction(target)
			else if dependenciesMetForKill()
				# We only kill when dependencies are already met, so that we minimize downtime
				return serviceAction('kill', target.serviceId, current, target)
			else
				return null
		'kill-then-download': (current, target) ->
			return serviceAction('kill', target.serviceId, current, target)
		'delete-then-download': (current, target, needsDownload) ->
			return serviceAction('kill', target.serviceId, current, target, removeImage: needsDownload)
		'hand-over': (current, target, needsDownload, dependenciesMetForStart, dependenciesMetForKill, needsSpecialKill, timeout) ->
			if needsDownload
				return fetchAction(target)
			else if needsSpecialKill and dependenciesMetForKill()
				return serviceAction('kill', target.serviceId, current, target)
			else if dependenciesMetForStart()
				return serviceAction('handover', target.serviceId, current, target, timeout: timeout)
			else
				return null
	}

	_nextStepForService: ({ current, target }, updateContext, localMode) =>
		{ targetApp, networkPairs, volumePairs, installPairs, updatePairs, availableImages, downloading } = updateContext
		if current?.status == 'Stopping'
			# There is already a kill step in progress for this service, so we wait
			return { action: 'noop' }

		if current?.status == 'Dead'
			# Dead containers have to be removed
			return serviceAction('remove', current.serviceId, current)

		needsDownload = false
		# Don't attempt to fetch any images in local mode, they should already be there
		if !localMode
			needsDownload = !_.some availableImages, (image) =>
				image.dockerImageId == target?.config.image or @images.isSameImage(image, { name: target.imageName })

		# This service needs an image download but it's currently downloading, so we wait
		if needsDownload and target?.imageId in downloading
			return { action: 'noop' }

		dependenciesMetForStart = =>
			@_dependenciesMetForServiceStart(target, networkPairs, volumePairs, installPairs.concat(updatePairs))
		dependenciesMetForKill = =>
			!needsDownload and @_dependenciesMetForServiceKill(target, targetApp, availableImages)

		# If the service is using a network or volume that is being updated, we need to kill it
		# even if its strategy is handover
		needsSpecialKill = @_hasCurrentNetworksOrVolumes(current, networkPairs, volumePairs)

		if current?.isEqualConfig(target)
			# We're only stopping/starting it
			return @_updateContainerStep(current, target)
		else if !current?
			# Either this is a new service, or the current one has already been killed
			return @_fetchOrStartStep(current, target, needsDownload, dependenciesMetForStart)
		else
			strategy = checkString(target.config.labels['io.resin.update.strategy'])
			validStrategies = [ 'download-then-kill', 'kill-then-download', 'delete-then-download', 'hand-over' ]
			if !_.includes(validStrategies, strategy)
				strategy = 'download-then-kill'
			timeout = checkInt(target.config.labels['io.resin.update.handover-timeout'])
			return @_strategySteps[strategy](current, target, needsDownload, dependenciesMetForStart, dependenciesMetForKill, needsSpecialKill, timeout)

	_nextStepsForAppUpdate: (currentApp, targetApp, localMode, availableImages = [], downloading = []) =>
		emptyApp = { services: [], volumes: {}, networks: {} }
		if !targetApp?
			targetApp = emptyApp
		else
			# Create the default network for the target app
			targetApp.networks['default'] ?= {}
		currentApp ?= emptyApp
		if currentApp.services?.length == 1 and targetApp.services?.length == 1 and
			targetApp.services[0].serviceName == currentApp.services[0].serviceName and
			checkTruthy(currentApp.services[0].config.labels['io.resin.legacy-container'])
				# This is a legacy preloaded app or container, so we didn't have things like serviceId.
				# We hack a few things to avoid an unnecessary restart of the preloaded app
				# (but ensuring it gets updated if it actually changed)
				targetApp.services[0].config.labels['io.resin.legacy-container'] = currentApp.services[0].labels['io.resin.legacy-container']
				targetApp.services[0].config.labels['io.resin.service-id'] = currentApp.services[0].labels['io.resin.service-id']
				targetApp.services[0].serviceId = currentApp.services[0].serviceId

		appId = targetApp.appId ? currentApp.appId
		networkPairs = @compareNetworksForUpdate({ current: currentApp.networks, target: targetApp.networks }, appId)
		volumePairs = @compareVolumesForUpdate({ current: currentApp.volumes, target: targetApp.volumes }, appId)
		{ removePairs, installPairs, updatePairs } = @compareServicesForUpdate(currentApp.services, targetApp.services)
		steps = []
		# All removePairs get a 'kill' action
		for pair in removePairs
			if pair.current.status != 'Stopping'
				steps.push(serviceAction('kill', pair.current.serviceId, pair.current, null))
			else
				steps.push({ action: 'noop' })

		# next step for install pairs in download - start order, but start requires dependencies, networks and volumes met
		# next step for update pairs in order by update strategy. start requires dependencies, networks and volumes met.
		for pair in installPairs.concat(updatePairs)
			step = @_nextStepForService(pair, { targetApp, networkPairs, volumePairs, installPairs, updatePairs, availableImages, downloading }, localMode)
			if step?
				steps.push(step)
		# next step for network pairs - remove requires services killed, create kill if no pairs or steps affect that service
		for pair in networkPairs
			pairSteps = @_nextStepsForNetwork(pair, currentApp, removePairs.concat(updatePairs))
			steps = steps.concat(pairSteps)
		# next step for volume pairs - remove requires services killed, create kill if no pairs or steps affect that service
		for pair in volumePairs
			pairSteps = @_nextStepsForVolume(pair, currentApp, removePairs.concat(updatePairs))
			steps = steps.concat(pairSteps)

		if _.isEmpty(steps) and currentApp.commit != targetApp.commit
			steps.push({
				action: 'updateCommit'
				target: targetApp.commit
			})

		return _.map(steps, (step) -> _.assign({}, step, { appId }))

	normaliseAppForDB: (app) =>
		services = _.map app.services, (s, serviceId) ->
			service = _.clone(s)
			service.appId = app.appId
			service.releaseId = app.releaseId
			service.serviceId = checkInt(serviceId)
			service.commit = app.commit
			return service
		Promise.map services, (service) =>
			service.image = @images.normalise(service.image)
			Promise.props(service)
		.then (services) ->
			dbApp = {
				appId: app.appId
				commit: app.commit
				name: app.name
				source: app.source
				releaseId: app.releaseId
				services: JSON.stringify(services)
				networks: JSON.stringify(app.networks ? {})
				volumes: JSON.stringify(app.volumes ? {})
			}
			return dbApp

	createTargetService: (service, opts) ->
		@images.inspectByName(service.image)
		.catchReturn(NotFoundError, undefined)
		.then (imageInfo) ->
			serviceOpts = {
				serviceName: service.serviceName
				imageInfo
			}
			_.assign(serviceOpts, opts)
			service.imageName = service.image
			if imageInfo?.Id?
				service.image = imageInfo.Id
			return Service.fromComposeObject(service, serviceOpts)

	normaliseAndExtendAppFromDB: (app) =>
		Promise.join(
			@config.get('extendedEnvOptions')
			@docker.getNetworkGateway(constants.supervisorNetworkInterface)
			.catchReturn('127.0.0.1')
			Promise.props({
				firmware: pathExistsOnHost('/lib/firmware')
				modules: pathExistsOnHost('/lib/modules')
			})
			fs.readFileAsync(path.join(constants.rootMountPoint, '/etc/hostname'), 'utf8').then(_.trim)
			(opts, supervisorApiHost, hostPathExists, hostnameOnHost) =>
				configOpts = {
					appName: app.name
					supervisorApiHost
					hostPathExists
					hostnameOnHost
				}
				_.assign(configOpts, opts)
				volumes = JSON.parse(app.volumes)
				volumes = _.mapValues volumes, (volumeConfig) ->
					volumeConfig ?= {}
					volumeConfig.labels ?= {}
					return volumeConfig
				Promise.map(JSON.parse(app.services), (service) => @createTargetService(service, configOpts))
				.then (services) ->
					# If a named volume is defined in a service, we add it app-wide so that we can track it and purge it
					for s in services
						serviceNamedVolumes = s.getNamedVolumes()
						for name in serviceNamedVolumes
							volumes[name] ?= { labels: {} }
					outApp = {
						appId: app.appId
						name: app.name
						commit: app.commit
						releaseId: app.releaseId
						services: services
						networks: JSON.parse(app.networks)
						volumes: volumes
					}
					return outApp
		)

	setTarget: (apps, dependent , source, trx) =>
		setInTransaction = (trx) =>
			Promise.try =>
				appsArray = _.map apps, (app, appId) ->
					appClone = _.clone(app)
					appClone.appId = checkInt(appId)
					appClone.source = source
					return appClone
				Promise.map(appsArray, @normaliseAppForDB)
				.tap (appsForDB) =>
					Promise.map appsForDB, (app) =>
						@db.upsertModel('app', app, { appId: app.appId }, trx)
			.then =>
				@proxyvisor.setTargetInTransaction(dependent, trx)

		Promise.try =>
			if trx?
				setInTransaction(trx)
			else
				@db.transaction(setInTransaction)
		.then =>
			@_targetVolatilePerImageId = {}

	setTargetVolatileForService: (imageId, target) =>
		@_targetVolatilePerImageId[imageId] ?= {}
		_.assign(@_targetVolatilePerImageId[imageId], target)

	clearTargetVolatileForServices: (imageIds) =>
		for imageId in imageIds
			@_targetVolatilePerImageId[imageId] = {}

	getTargetApps: =>
		@config.getMany(['apiEndpoint', 'localMode']). then ({ apiEndpoint, localMode }) =>
			source = apiEndpoint
			if checkTruthy(localMode)
				source = 'local'
			Promise.map(@db.models('app').where({ source }), @normaliseAndExtendAppFromDB)
		.map (app) =>
			if !_.isEmpty(app.services)
				app.services = _.map app.services, (service) =>
					if @_targetVolatilePerImageId[service.imageId]?
						_.merge(service, @_targetVolatilePerImageId[service.imageId])
					return service
			return app
		.then (apps) ->
			return _.keyBy(apps, 'appId')

	getDependentTargets: =>
		@proxyvisor.getTarget()

	bestDeltaSource: (image, available) ->
		if !image.dependent
			for availableImage in available
				if availableImage.serviceName == image.serviceName and availableImage.appId == image.appId
					return availableImage.name
			for availableImage in available
				if availableImage.serviceName == image.serviceName
					return availableImage.name
		for availableImage in available
			if availableImage.appId == image.appId
				return availableImage.name
		return 'resin/scratch'

	# returns:
	# imagesToRemove: images that
	# - are not used in the current state, and
	# - are not going to be used in the target state, and
	# - are not needed for delta source / pull caching or would be used for a service with delete-then-download as strategy
	# imagesToSave: images that
	# - are locally available (i.e. an image with the same digest exists)
	# - are not saved to the DB with all their metadata (serviceId, serviceName, etc)
	_compareImages: (current, target, available, localMode) =>
		allImagesForTargetApp = (app) -> _.map(app.services, imageForService)
		allImagesForCurrentApp = (app) ->
			_.map app.services, (service) ->
				img = _.find(available, { dockerImageId: service.config.image, imageId: service.imageId }) ? _.find(available, { dockerImageId: service.config.image })
				return _.omit(img, [ 'dockerImageId', 'id' ])

		availableWithoutIds = _.map(available, (image) -> _.omit(image, [ 'dockerImageId', 'id' ]))
		currentImages = _.flatMap(current.local.apps, allImagesForCurrentApp)
		targetImages = _.flatMap(target.local.apps, allImagesForTargetApp)

		availableAndUnused = _.filter availableWithoutIds, (image) ->
			!_.some currentImages.concat(targetImages), (imageInUse) -> _.isEqual(image, imageInUse)

		imagesToDownload = _.filter targetImages, (targetImage) =>
			!_.some available, (availableImage) => @images.isSameImage(availableImage, targetImage)

		# Images that are available but we don't have them in the DB with the exact metadata:
		imagesToSave = []
		if !localMode
			imagesToSave = _.filter targetImages, (targetImage) =>
				_.some(available, (availableImage) => @images.isSameImage(availableImage, targetImage)) and
					!_.some availableWithoutIds, (img) -> _.isEqual(img, targetImage)

		deltaSources = _.map imagesToDownload, (image) =>
			return @bestDeltaSource(image, available)
		proxyvisorImages = @proxyvisor.imagesInUse(current, target)

		imagesToRemove = _.filter availableAndUnused, (image) =>
			notUsedForDelta = !_.includes(deltaSources, image.name)
			notUsedByProxyvisor = !_.some proxyvisorImages, (proxyvisorImage) => @images.isSameImage(image, { name: proxyvisorImage })
			return notUsedForDelta and notUsedByProxyvisor
		return { imagesToSave, imagesToRemove }

	_inferNextSteps: (cleanupNeeded, availableImages, downloading, supervisorNetworkReady, current, target, ignoreImages, { localMode, delta }) =>
		localMode = checkTruthy(localMode)
		delta = checkTruthy(delta)
		Promise.try =>
			if localMode
				ignoreImages = true
			currentByAppId = current.local.apps ? {}
			targetByAppId = target.local.apps ? {}
			nextSteps = []
			if !supervisorNetworkReady
				nextSteps.push({ action: 'ensureSupervisorNetwork' })
			else
				if !ignoreImages and _.isEmpty(downloading)
					if cleanupNeeded
						nextSteps.push({ action: 'cleanup' })
					{ imagesToRemove, imagesToSave } = @_compareImages(current, target, availableImages, localMode)
					for image in imagesToSave
						nextSteps.push({ action: 'saveImage', image })
					if _.isEmpty(imagesToSave)
						for image in imagesToRemove
							nextSteps.push({ action: 'removeImage', image })
				# If we have to remove any images, we do that before anything else
				if _.isEmpty(nextSteps)
					allAppIds = _.union(_.keys(currentByAppId), _.keys(targetByAppId))
					for appId in allAppIds
						nextSteps = nextSteps.concat(@_nextStepsForAppUpdate(currentByAppId[appId], targetByAppId[appId], localMode, availableImages, downloading))
			newDownloads = _.filter(nextSteps, (s) -> s.action == 'fetch').length
			if !ignoreImages and delta and newDownloads > 0
				downloadsToBlock = downloading.length + newDownloads - constants.maxDeltaDownloads
				while downloadsToBlock > 0
					_.pull(nextSteps, _.find(nextSteps, action: 'fetch'))
					downloadsToBlock -= 1
			if !ignoreImages and _.isEmpty(nextSteps) and !_.isEmpty(downloading)
				nextSteps.push({ action: 'noop' })
			return _.uniqWith(nextSteps, _.isEqual)

	stopAll: ({ force = false, skipLock = false } = {}) =>
		@services.getAll()
		.map (service) =>
			@_lockingIfNecessary service.appId, { force, skipLock }, =>
				@services.kill(service, { removeContainer: false, wait: true })
				.then =>
					delete @_containerStarted[service.containerId]

	_lockingIfNecessary: (appId, { force = false, skipLock = false } = {}, fn) =>
		if skipLock
			return Promise.try(fn)
		@config.get('lockOverride')
		.then (lockOverride) ->
			return checkTruthy(lockOverride) or force
		.then (force) ->
			updateLock.lock(appId, { force }, fn)

	executeStepAction: (step, { force = false, skipLock = false } = {}) =>
		if _.includes(@proxyvisor.validActions, step.action)
			return @proxyvisor.executeStepAction(step)
		if !_.includes(@validActions, step.action)
			return Promise.reject(new Error("Invalid action #{step.action}"))
		@actionExecutors[step.action](step, { force, skipLock })

	getRequiredSteps: (currentState, targetState, ignoreImages = false) =>
		@config.get('localMode').then (localMode) =>
			Promise.join(
				@images.isCleanupNeeded()
				@images.getAvailable(localMode)
				@images.getDownloadingImageIds()
				@networks.supervisorNetworkReady()
				@config.get('delta')
				(cleanupNeeded, availableImages, downloading, supervisorNetworkReady, delta) =>
					conf = { delta, localMode }
					if localMode
						cleanupNeeded = false
					@_inferNextSteps(cleanupNeeded, availableImages, downloading, supervisorNetworkReady, currentState, targetState, ignoreImages, conf)
					.then (nextSteps) =>
						if ignoreImages and _.some(nextSteps, action: 'fetch')
							throw new Error('Cannot fetch images while executing an API action')
						@proxyvisor.getRequiredSteps(availableImages, downloading, currentState, targetState, nextSteps)
						.then (proxyvisorSteps) ->
							return nextSteps.concat(proxyvisorSteps)
			)

	serviceNameFromId: (serviceId) =>
		@getTargetApps().then (apps) ->
			# Multi-app warning!
			# We assume here that there will only be a single
			# application
			for appId, app of apps
				return _.find app.services, (svc) ->
					svc.serviceId == serviceId
		.get('serviceName')
