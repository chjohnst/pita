#!/usr/bin/env ruby

require 'sinatra'
require 'rb-inotify'
require 'eventmachine'
require 'em-http'
require 'yaml'
require 'yaml/store'
require 'json'
require 'log4r'

require './lib/yaml_ops'

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
  alias_method :h, :escape_html
end

class FileWatcher
  attr_reader :path, :notifier
  @@count = 0

  def initialize(path)
    @path     = path
    @notifier = INotify::Notifier.new

    #give a hint to inotify settings
    if File.file? '/proc/sys/fs/inotify/max_user_watches'
      max_user_watches = File.open('/proc/sys/fs/inotify/max_user_watches').read
      if max_user_watches.to_i < 5000
        $log.info "You should increase fs.inotify.max_user_watches to at least 5000"
      end
    end

    @notifier.watch(@path, :recursive, :modify) do |event|
      self.callback(event)
    end
    @@count += 1
  end

  def count
    @@count
  end

  def run
    @notifier.run
  end

  def callback(event)
    changed_file = event.absolute_name.sub(/#{$config['database_directory']}/, '')
    $log.debug "#{changed_file} changed! Evaluate callbacks."

    YamlOps.load_yaml($config['callback_file']).each do |path, action|
      if changed_file == path
        if File.executable? action.split(/ /).first
          $log.info "Callback triggered for #{path}. Will execute #{action}"
          begin
            run = EM::DeferrableChildProcess.open(action)
            run.callback{$log.info "Command finished."}
          rescue Exception => e
            $log.error "Can not run command #{action}"
            $log.debug e.message
          end
        else
          $log.info "Callback triggered for #{path}. Will request #{action}"
          begin
            request = EM::HttpRequest.new(action).get
            request.callback{$log.info "Request finished."}
          rescue Exception => e
            $log.error "Can not request url #{action}"
            $log.debug e.message
          end
        end
      end
    end
  end
end

# --- background thread ---
file_observer = Thread.new do
  # we wait till the application is up and running
  sleep 0.5 while not Sinatra::Application.running?

  watcher = FileWatcher.new($config['database_directory'])
  Thread.exit if watcher.count > 1

  $log.info "Observe #{$config['database_directory']} for changes with #{watcher.count.to_s} watcher."
  if not EventMachine.reactor_running?
    # we use our own reactor
    EM.run do
      watcher.run
    end
  else
    # we use e.g. thin's reactor
    watcher.run
  end
end

# --- filter ---
before do
  headers 'Content-Type' => "application/json;charset=utf-8"
end

$log.info "Database up and running!"

# --- getter ---
get '/debug' do
  file_observer.inspect
end

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

def list_entries(path)
  result      = []
  working_dir = File.join( $config['database_directory'], path )
  
  if File.directory? working_dir
    Dir.glob( File.join( working_dir, '*.yaml' ) ) do |entry|
      finding = Hash.new
      finding['name'] = File.basename(entry, '.yaml')
      if File.directory?(File.join(File.split(entry).first, finding['name']))
        finding['type'] = 'Directory'
      else
        finding['type'] = 'File'
      end
      finding['url']  = uri(File.join('properties', path, finding['name']))

      result << finding
    end
  elsif File.file?( working_dir + '.yaml' )
    finding = Hash.new
    finding['name'] = File.basename(working_dir, '.yaml')
    finding['type'] = 'File'
    finding['url']  = uri(File.join('properties', path, 'eachpair'))
    result          = finding
  else
    return_error( 404, "Can not find any data under '#{working_dir}'" )    
  end
  
  return result
end

def list_views
  result      = []

  if File.directory? $config['view_directory']
    Dir.glob( File.join( $config['view_directory'], '*.yaml' ) ) do |entry|
      finding = Hash.new
      finding['name'] = File.basename(entry, '.yaml')
      finding['type'] = 'View'
      finding['url']  = uri(File.join('view', finding['name']))

      result << finding
    end
  else
    return_error( 404, "Can not find any view under '#{$config['view_directory']}'" )
  end

  return result
end

def read_data(path, options={})
  data       = Hash.new
  actual_dir = $config['database_directory'] 
  filename   = ''

  steps = path.split('/')
  $log.debug "Start reading #{steps.inspect}"

  steps.each do |step|
    actual_dir = File.join( actual_dir, step.to_s )
    filename   = actual_dir + '.yaml'

    $log.debug "Reading: #{File.expand_path(filename)}"
    begin
      sub_data = load_yaml(filename)
    rescue Exception => e
      $log.debug e.message
      return_error( 404, "Can not read #{filename} in database" )
    end

    if sub_data.is_a?(Hash)
      if options[:disable_merge]
        data = sub_data
      else
        data.merge!( sub_data )
      end
    end
  end
  return data
end

def read_view(view)
  filename = File.join($config['view_directory'], "#{File.basename(view, '.yaml')}.yaml")
  if File.file?(filename)
    list = load_yaml(filename)
  else
    begin
      list = JSON.parse view
    rescue
      return_error( 400, "Can not parse your view data: #{view}" )
    end
  end
  data = Hash.new
  type = list.keys.first
  list[type].each do |entry|
    case type
      when 'list'
        data[entry] = read_data(entry)
      when 'merge'
        data = data.merge! read_data(entry)
      else
        return_error( 406, "View type #{type} is not allowed" )
    end
  end
  return data
end

def get_relevantfile(path, key)
  data          = Hash.new
  actual_dir    = $config['database_directory']
  filename      = ''
  relevant_file = ''

  steps = path.split('/')
  
  steps.each do |step|
    actual_dir = File.join( actual_dir, step.to_s )
    filename = actual_dir + '.yaml'
    
    $log.debug "Reading: #{File.expand_path(filename)}"
    begin
      data = load_yaml(filename)
    rescue Exception => e
      $log.debug e.message
      return_error( 404, "Can not read #{filename} in database" )
    end
    
    if not data.nil? and data.has_key?(key)
      relevant_file = File.expand_path(filename)
    end
  end
  return_error( 404, "Can not find Key #{key} in path #{path}" ) if relevant_file.empty?
  return relevant_file
end

