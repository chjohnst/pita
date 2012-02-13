module YamlOps
  def load_yaml(filename)
    result = ""
    if File.file? filename
        begin
          result = YAML::load_file(filename)
        rescue StringIndexOutOfBoundsException => e
          $log.error "YAML parsing in #{filename}"
          $log.debug e.message
          raise "YAML not parsable"
          false
        rescue Exception => e
          $log.error "YAML parsing in #{filename}"
          $log.debug e.message
          raise "YAML not parsable"
          false
        end
    else
      raise "File nod found: #{filename}"
    end
    raise "Not a yaml file: #{filename}" if result == false
    
    return result
  end
  
  def create_empty_yaml(path)
    actual_dir = $config['database_directory']
  
    steps = path.split('/')
    steps.each do |step|
      next if step.empty?
  
      actual_dir = File.join(actual_dir, step)
      begin
        unless File.directory? actual_dir
          FileUtils.mkdir_p actual_dir
          $log.info "Created directory #{actual_dir}"
        end
        unless File.file? actual_dir + '.yaml'
          File.open(actual_dir + '.yaml', 'w') do |yaml_file|
            YAML.dump(Hash.new, yaml_file)
          end
          $log.info "Created file #{actual_dir + '.yaml'}"
        end
      rescue Exception => e
        $log.error "Can not create #{actual_dir}"
        $log.debug e.message
      end
    end
  
    return true
  end
  
  def update_yaml(path, data)
    file = File.join( $config['database_directory'], path + '.yaml')
    unless File.file? file
      return_error 404, "Path #{path} does not exists"
    end
  
    begin
      store = YAML::Store.new( file, :Indent => 2 )
      $log.info "Updating #{File.expand_path file}"
      store.transaction do
        return_error 500, "Not a valid YAML #{File.expand_path file}"  if store.nil?
        data.each_pair do |key, value|
          store[key] = value
        end
      end
    rescue Exception => e
      return_error 500, "Can write to YAML file #{File.expand_path file}"
    end
  
    return true
  end
  
  def delete_key_in_yaml(path, key)
    file = get_relevantfile(path, key)
  
    begin
      store = YAML::Store.new( file, :Indent => 2)
      $log.info "Deleting #{key} from #{path} in #{file}"
      store.transaction do
        if store.nil?
            $log.error "Not a valid yaml #{File.expand_path(file)}"
        else
          store.delete(key)
        end
      end
    rescue Exception => e
      $log.error "While deleting key #{key} from #{file}"
      $log.debug e.message
    end
  end
end

