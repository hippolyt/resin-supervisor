require('coffee-script');
var knex = require('./db')

// Wait for the DB schema to be created
knex.init.then(function () {
	require('./app');
})
