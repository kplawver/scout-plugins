class ProcessUsage < Scout::Plugin  
  MEM_CONVERSION = 1024
  
  OPTIONS=<<-EOS
  command_name:
    name: Command Name
    notes: The name of the process you want to monitor.
  pid_file:
    name: PID File
    notes: The full path to the PID file for the process to monitor.
           Optional. If absent, the process found with the specified command name is used.
  ps_command:
    name: The Process Status (ps) Command
    notes: The command with options. The default works on most systems.
    default: ps auxww
  ps_regex:
    name: The regex used to match a command name.
    notes: "By default, this matches a command name anywhere in the ps output line.  The word COMMAND get's replaced with the command you gave (regex escaped).  You may wish to try the following pattern if you only want to match a command in the last column:  (?i:COMMAND\\s+$)"
    default: "(?i:\\bCOMMAND\\b)"
  alert_when_command_not_found:
    name: Alert when command not found
    notes: Specifies if an error is reported when no commands are found.  Use 0 to disable alert.
    default: 1
    attributes: advanced
  EOS
  
  def build_report
    if missing_required_options?
      return error("Please specify the name of the monitored process or the path to its PID file.")
    end
    ps_command,ps_regex = nil
    if option(:pid_file) and !option(:pid_file).empty?
      begin
        pid = File.open(option(:pid_file)).readline.strip
      rescue Exception => e
        return error("Unable to read PID file","Unable to read the PID file [#{option(:pid_file)}]:\n\n#{e.message}")
      end
      if pid.nil? 
        return error("PID file is blank","The PID file [#{option(:pid_file)}] is blank.")
      end
      ps_command   = "ps uww -p #{pid}"
    else
      ps_command   = option(:ps_command) || "ps auxww"
      ps_regex     = (option(:ps_regex) || "(?i:\\bCOMMAND\\b)").to_s.gsub("COMMAND") { Regexp.escape(option(:command_name)) }
    end
      
    alert_when_command_not_found = option(:alert_when_command_not_found).to_s != '0'  

    ps_output = `#{ps_command}`
    unless $?.success?
      return error("Couldn't use `ps` as expected.", error.message)
    end
    ps_lines = ps_output.split(/\n/)
    fields   = ps_lines.shift.downcase.split
    unless (memory_index = fields.index("rss")) && (pid_index = fields.index('pid'))
      return error( "RSS or PID field not found.",
                    "The output from `#{ps_command}` did not include the needed RSS and PID fields." )
    end
    unless cpu_index = fields.index("%cpu")
      return error( "%CPU field not found.",
                    "The output from `#{ps_command}` did not include the needed %CPU field." )
    end

    # narrow the ps lines to just those mentioning the process we're interested in
    process_lines = if ps_regex 
      ps_lines.grep(Regexp.new(ps_regex)) 
    else
      ps_lines
    end

    if process_lines.any?
      rss_values = process_lines.map { |com| Float(com.split[memory_index]).abs }
      pids       = process_lines.map { |com| Integer(com.split[pid_index]) }
      highest_rss    = rss_values.max
      total_rss      = rss_values.inject(0){|s,value| s + value }
      restarts   = 0
      
      cpu_values = process_lines.map { |com| Float(com.split[cpu_index]).abs }
      highest_cpu = cpu_values.max
      total_cpu  = cpu_values.inject(0){|s,value| s + value }

      if remembered_pids = memory(:pids)
        # Find how many new pids we haven't seen before
        new_pids     = (pids - remembered_pids).length

        # Find how many more pids we have now than before
        started_pids = pids.length - remembered_pids.length
        started_pids = 0 if started_pids < 1

        # Don't include newly started processes as restarts
        restarts = new_pids - started_pids
      end

      report(:memory        => (highest_rss/MEM_CONVERSION).to_i,
             :total_rss     => (total_rss/MEM_CONVERSION).to_i,
             :num_processes => process_lines.size,
             :restarts      => restarts,
             :cpu           => highest_cpu,
             :total_cpu     => total_cpu)

      remember(:pids => pids)
    else
      report(:num_processes => 0)
      if alert_when_command_not_found
        error( "Command not found.", "No processes found matching #{option(:command_name)}." )
      end
    end
  end
  
  def missing_required_options?
    (option(:command_name).nil? or option(:command_name).empty?) and (option(:pid_file).nil? or option(:pid_file).empty?)
  end
  
end
