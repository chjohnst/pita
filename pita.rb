#!/usr/bin/env ruby

require 'sinatra'
require 'rb-inotify'
require 'eventmachine'
require 'em-http'
require 'yaml'
require 'yaml/store'
require 'json'
require 'log4r'
require 'thread'

require_relative 'lib/yaml_ops'
require_relative 'lib/file_watcher'
require_relative 'lib/file_ops'

include Log4r

# load configuration settings
$config = YAML::load_file(File.join(File.dirname(__FILE__), 'etc', 'config.yaml'))

if jruby = RUBY_PLATFORM =~ /\bjava\b/
  puts "Sorry, jruby is not supported!"
  exit 1
end

# initialzie logging
outputter       = Log4r::FileOutputter.new('PITA_LOG_FILE', \
                                            :filename => $config['log_file'])
outputter.level = Log4r::Log4rConfig::LogLevels.index($config['log_level']) + 1
$log            = Logger.new 'PITA'
$log.trace      = false
$log.add(outputter)

# --- helper ---
helpers do
  include Rack::Utils
  include YamlOps
  include FileOps
  alias_method :h, :escape_html
end

# --- background thread ---
file_observer = Thread.new do
  # we wait till the application is up and running
  sleep 0.5 while not Sinatra::Application.running?

  watcher = FileWatcher.new($config['database_directory'])
  Thread.exit if FileWatcher.count > 1

  $log.info "Observe #{$config['database_directory']} for changes with #{FileWatcher.count} watcher."
  EM.run do
    watcher.run
  end
end

# --- filter ---
before do
  content_type :json
end

$log.info "Database up and running!"

# --- getter ---
get '/properties/*/key/:key.filename' do
  result = get_relevantfile(params[:splat].first, params[:key])

  if result.nil?
    return_error( 404, "Key '#{params[:key]}' not found" )
  else
    {params[:key] => result}.to_json
  end
end

get '/properties/*/key/:key' do
  data      = read_data(params[:splat].first)
  extension = File.extname(params[:key])
  key       = File.basename(params[:key], extension)
  result    = data[key]

  if result.nil?
    return_error( 404, "Key '#{key}' not found" )
  end
  if (not extension.empty?) and extension != '.json'
    return_error( 400, "Output format not supported" )
  end

  {key => result}.to_json
end

get '/properties/*/eachpair*' do
  data      = read_data(params[:splat].first)
  extension = params[:splat].last

  if (not extension.empty?) and extension != '.json'
    return_error( 400, "Output format not supported" )
  end
  if data.nil?
    return_error( 404, "Path '#{params[:splat]}' not found" )
  end
  data.to_json
end

[ '/', '/properties', '/properties/*' ].each do |url|
  get url do
    unless params[:splat].nil?
      path = params[:splat].first
    else
      path = '/'
    end

    list_entries(path).to_json
  end
end

get '/views' do
  list_views.to_json
end

get '/view/*' do
  read_view(params[:splat].first).to_json
end

post '/view' do
  read_view(request.body.read.to_s).to_json
end

get '/*' do
  return_error( 404, "Request doesn't match a valid route" )
end

# --- setter ---
put '/properties/*' do
  begin
    data = JSON.parse(request.body.read.to_s)
  rescue
    return_error( 400, "Bad JSON received" )
  end

  update_yaml( params[:splat].first, data )
  redirect '/', 200
end

put '/*' do
  return_error( 404, "Request doesn't match a valid route" )
end

post '/*' do
  begin
    data = JSON.parse(request.body.read.to_s)
  rescue
    return_error( 400, "Bad JSON received" )
  end
  
  create_empty_yaml( data['path'] )
  redirect '/', 200
end

delete '/properties/*/:key' do
  delete_key_in_yaml( params[:splat].first, params[:key] )
  redirect '/', 200
end

# --- private functions ---
private
def return_error(code, message)
  $log.error message
    redirect '/', code, {:status => 2, \
                         :error_message => message}.to_json
end

