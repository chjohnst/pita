module FileOps
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
        sub_data = YamlOps.load_yaml(filename)
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
      list = YamlOps.load_yaml(filename)
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
        data = YamlOps.load_yaml(filename)
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
end
