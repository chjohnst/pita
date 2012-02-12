class FileWatcher
  attr_reader :path, :notifier
  @@mutex = Mutex.new
  @@count = 0

  def self.count
    @@count
  end

  def self.count=(value)
    @@count = value
  end

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
    @@mutex.synchronize do
      self.class.count += 1
    end
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

