ENV['RACK_ENV'] = 'test'
require 'minitest/autorun'
require 'rack/test'
require 'json'

require 'pita'

def app
  Sinatra::Application
end

def json_response
  JSON.parse last_response.body
end

