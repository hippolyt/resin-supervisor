var webpack = require('webpack');
var path = require('path');
var fs = require('fs');
var _ = require('lodash');
var path = require('path');
var UglifyPlugin = require("uglifyjs-webpack-plugin");
const CopyWebpackPlugin = require('copy-webpack-plugin');

var externalModules = [
	'mkfifo',
	'sqlite3',
	'mysql2',
	'pg',
	'mariasql',
	'mssql',
	'mysql',
	'strong-oracle',
	'oracle',
	'oracledb',
	'pg-query-stream'
]

var requiredModules = []
var maybeOptionalModules = []
lookForOptionalDeps = function (sourceDir) {
	// We iterate over the node modules and mark all optional dependencies as external
	var dirs = fs.readdirSync(sourceDir)
	for (let dir of dirs) {
		let packageJson = {};
		let internalNodeModules = path.join(sourceDir, dir, 'node_modules');
		if (fs.existsSync(internalNodeModules)) {
			lookForOptionalDeps(internalNodeModules);
		}
		try {
			packageJson = JSON.parse(fs.readFileSync(path.join(sourceDir, dir, '/package.json')));
		}
		catch (e) {
			continue;
		}
		if (packageJson.optionalDependencies != null){
			maybeOptionalModules = maybeOptionalModules.concat(_.keys(packageJson.optionalDependencies))
		}
		if (packageJson.dependencies != null){
			requiredModules = requiredModules.concat(_.keys(packageJson.dependencies))
		}
	}
}

lookForOptionalDeps('./node_modules')
externalModules.push(new RegExp('^(' + _.reject(maybeOptionalModules, requiredModules).map(_.escapeRegExp).join('|') + ')(/.*)?$'));

console.log('Using the following dependencies as external:', externalModules);

module.exports = function (env) {
	let plugins = [
		new webpack.DefinePlugin({
			'process.env.NODE_ENV': '"production"',
		}),
		new CopyWebpackPlugin([
			{
				from: './src/migrations',
				to: 'migrations'
			}
		]),
		new webpack.ContextReplacementPlugin(
			/\.\/migrations/,
			path.resolve(__dirname, 'src/migrations')
		)
	]
	if (env == null || !env.noOptimize) {
		plugins.push(new UglifyPlugin())
	}
	return {
		entry: './src/app.coffee',
		output: {
			filename: 'app.js',
			path: path.resolve(__dirname, 'dist')
		},
		resolve: {
			extensions: [".js", ".ts", ".json", ".coffee"]
		},
		target: 'node',
		node: {
			__dirname: false
		},
		module: {
			rules: [
				{
					test: /knex\/lib\/migrate\/index\.js$/,
					use: require.resolve('./hardcode-migrations')
				},
				{
					test: /JSONStream\/index\.js$/,
					use: require.resolve('./fix-jsonstream')
				},
				{
					test: /\.coffee$/,
					use: require.resolve('coffee-loader')
				},
				{
					test: /\.ts$/,
					use: [
						{
							loader: 'ts-loader',
						}
					]
				}
			]
		},
		externals: (context, request, callback) => {
			for (let m of externalModules) {
				if ((typeof m === 'string' && m === request) || (m instanceof RegExp && m.test(request))) {
					return callback(null, 'commonjs ' + request);
				} else if (typeof m != 'string' && !(m instanceof RegExp)) {
					throw new Error('Invalid entry in external modules: ' + m);
				}
			}
			return callback()
		},
		plugins: plugins
	};
}
