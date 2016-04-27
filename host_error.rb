#!/usr/bin/env ruby

# -------------------------------------------------------------------------- #
# Copyright 2002-2015, OpenNebula Project (OpenNebula.org), C12G Labs        #
#                                                                            #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    #
# not use this file except in compliance with the License. You may obtain    #
# a copy of the License at                                                   #
#                                                                            #
# http://www.apache.org/licenses/LICENSE-2.0                                 #
#                                                                            #
# Unless required by applicable law or agreed to in writing, software        #
# distributed under the License is distributed on an "AS IS" BASIS,          #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   #
# See the License for the specific language governing permissions and        #
# limitations under the License.                                             #
#--------------------------------------------------------------------------- #

##############################################################################
# Script to implement host failure tolerance
#   It can be set to
#           -m migrate VMs to another host. Only for images in shared storage
#           -r recreate VMs running in the host. State will be lost.
#           -d delete VMs running in the host
#   Additional flags
#           -f force resubmission of suspended VMs
#           -p <n> avoid resubmission if host comes
#                  back after n monitoring cycles
##############################################################################

##############################################################################
# WARNING! WARNING! WARNING! WARNING! WARNING! WARNING! WARNING! WARNING!
#
# This script needs to fence the error host to prevent split brain VMs. You
# may use any fence mechanism and invoke it around L105, using host_name
#
# WARNING! WARNING! WARNING! WARNING! WARNING! WARNING! WARNING! WARNING!
#############################################################################

ONE_LOCATION=ENV["ONE_LOCATION"]

if !ONE_LOCATION
    RUBY_LIB_LOCATION="/usr/lib/one/ruby"
    VMDIR="/var/lib/one"
    CONFIG_FILE="/var/lib/one/config"
else
    RUBY_LIB_LOCATION=ONE_LOCATION+"/lib/ruby"
    VMDIR=ONE_LOCATION+"/var"
    CONFIG_FILE=ONE_LOCATION+"/var/config"
end


$: << RUBY_LIB_LOCATION

require 'opennebula'
include OpenNebula

require 'getoptlong'

# jojo: needed for executing shell commands
require "CommandManager"
# jojo: for debugging purposes
require "pp"


# jojo: for parsing host templae and reading xml
require 'base64'
require 'nokogiri'

# jojo: logging to syslog
require 'syslog'

def slog(message)
    Syslog.open("OpenNebula "+$0.split("/").last, Syslog::LOG_PID | Syslog::LOG_CONS) { |s| s.notice message }
end


if !(host_id=ARGV[0])
    exit -1
end

# jojo: get IPMI data from $TEMPLATE (see oned.conf from where this script is called!)
if !(host_template=ARGV[1])
	exit -1
end

mode   = "-r" # By default, recreate VMs
force  = "n"  # By default, don't recreate/delete suspended VMs
repeat = nil  # By default, don't wait for monitorization cycles"

opts = GetoptLong.new(
            ['--migrate',  '-m',GetoptLong::NO_ARGUMENT],
            ['--delete',   '-d',GetoptLong::NO_ARGUMENT],
            ['--recreate', '-r',GetoptLong::NO_ARGUMENT],
            ['--force',    '-f',GetoptLong::NO_ARGUMENT],
            ['--pause',    '-p',GetoptLong::REQUIRED_ARGUMENT]
        )

begin
    opts.each do |opt, arg|
        case opt
            when '--migrate'
                mode="-m"
            when '--delete'
                mode="-d"
            when '--recreate'
                mode="-r"
            when '--force'
                force  = "y"
            when '--pause'
                repeat = arg.to_i
        end
    end
rescue Exception => e
    exit(-1)
end

begin
    client = Client.new()
rescue Exception => e
    puts "Error: #{e}"
    exit -1
end

# Retrieve hostname
host  =  OpenNebula::Host.new_with_id(host_id, client)

# jojo: retrieve host object lil different: crap???
#xml=OpenNebula::Host.build_xml
#host=OpenNebula::Host.new(xml, client)

rc = host.info
exit -1 if OpenNebula.is_error?(rc)
host_name = host.name

# jojo: trying to get ipmi data from host instance....

#meth = host.methods
#string = pp(meth)
#for i in string
#  command = LocalCommand.run("echo \"pp methods i: " + i + "\" >> /var/lib/one/roland")
#end
# Error: can't convert Symbol into String (TypeError)

#host_info = pp(host.info)
# error nil

#command=LocalCommand.run("echo \"pp host: " + host_info + "\" >> /var/lib/one/roland")
#for i in host_info
#  command=LocalCommand.run("echo \"pp host.info i: " + i + "\" >> /var/lib/one/roland")
#end
# + i +
# Error : undefined method `each' for nil:NilClass (NoMethodError)

# host_info = pp(host) -> for ...
# Tue Apr  5 16:55:00 2016 [Z0][HKM][D]: Message received: LOG I 7 /usr/lib/one/ruby/opennebula/xml_element.rb:192:in `each': wrong number of arguments (0 for 1) (ArgumentError)

# host_info = pp(host)
# gibt was zurück!!!!!
#Message received:  @client=
#
#Tue Apr  5 17:07:05 2016 [Z0][HKM][D]: Message received:   #<OpenNebula::Client:0x0000000286b508
#Tue Apr  5 17:07:05 2016 [Z0][HKM][D]: Message received:    @async=true,
#Tue Apr  5 17:07:05 2016 [Z0][HKM][D]: Message received:    @one_auth="oneadmin:arnedWimVaf2",
#Tue Apr  5 17:07:05 2016 [Z0][HKM][D]: Message received:    @one_endpoint="http://localhost:2633/RPC2",


#host_info = pp(host.@xml)
#Tue Apr  5 17:30:15 2016 [Z0][HKM][D]: Message received: LOG I 7 /var/lib/one/remotes//hooks/ft/host_error.rb:144: syntax error, unexpected tIVAR
#Tue Apr  5 17:30:15 2016 [Z0][HKM][D]: Message received: LOG I 7 host_info = pp(host.@xml)
#Tue Apr  5 17:30:15 2016 [Z0][HKM][D]: Message received: LOG I 7 ^
#Tue Apr  5 17:30:15 2016 [Z0][HKM][D]: Message received: LOG I 7 ExitCode: 1
#Tue Apr  5 17:30:15 2016 [Z0][HKM][D]: Message received: EXECUTE FAILURE 7 error: -

# from cli, require error :-/ /usr/lib/ruby/1.9.1/rubygems/custom_require.rb:36:in `require': cannot load such file -- one_helper (LoadError) 
# probably because of sub path cli
#hosthelper=OneHostHelper.new()
#host_info = pp(hosthelper)


#### configure fencing START ######################
# which fence agent to use
fence_agent="/usr/sbin/fence_ipmilan"
# retry fence action this many times if unsucessful
fence_retry=3
# wait this many seconds between retries
fence_retry_wait=10
# onoff or cycle
fence_method="cycle"
# -T Wait X seconds after on/off operation (Default Value: 2), set to 4 for HP iLO 3 
fence_wait="2"
# fence_timeout (-t Timeout (sec) for IPMI operation)
fence_timeout="5"
#### configure fencing STOP #######################


# decode host template
host_template_decoded=Base64.decode64(host_template)
# create xml object
xml=Nokogiri::Slop(host_template_decoded)
#host_info = pp(xml.methods)
# retrieve necessary data for fencing command from host template
ipmi_ip=xml.HOST.TEMPLATE.IPMI_IP.content
ipmi_user=xml.HOST.TEMPLATE.IPMI_USER.content
ipmi_pass=xml.HOST.TEMPLATE.IPMI_PASS.content


if repeat
    # Retrieve host monitor interval
    monitor_interval = nil
    File.readlines(CONFIG_FILE).each{|line|
         monitor_interval = line.split("=").last.to_i if /MONITORING_INTERVAL/=~line
    }
    # Sleep through the desired number of monitor interval
    sleep (repeat * monitor_interval)

    # If the host came back, exit! avoid duplicated VMs
    exit 0 if host.state != 3
end

#jojo: the actual fence command
fence_cmd=LocalCommand.new(fence_agent+" -a "+ipmi_ip+" -P -l X"+ipmi_user+" -p "+ipmi_pass+" -o reboot -v -M "+fence_method+" -T "+fence_wait+" -t "+fence_timeout)

#methods = pp(fence_cmd.public_methods)
#puts("executing fence command: " + fence_cmd.command)

fence_successful=false
fence_tried=0
puts "DEBUG: FIRST PUTS, BEFORE WHILE LOOP"
puts "DEBUG: BEFORE WHILE LOOP"
while fence_successful != true

    if fence_tried > fence_retry
       #slog("#{host_name}(#{host_id}) ERROR: tried fence command "+(fence_tried-1).to_s+" times, giving up!") 
       puts("tried fence command "+(fence_tried-1).to_s+" times, giving up!") 
       #STDOUT.flush
       break
    end

    #fence_cmd.run
    #STDOUT.flush
    
    #if fence_cmd.stdout.include?("Failed")
    #    #puts("fence command returned error code "+fence_cmd.code.to_s+", message was: "+fence_cmd.get_error_message+", stdout was: "+fence_cmd.stdout)
    #    puts("fence command not successful, stdout was: "+fence_cmd.stdout)
    #    #STDOUT.flush
    #else
    #    puts("fence command successful, stdout was: "+fence_cmd.stdout)
    #    #STDOUT.flush
    #    fence_successful=true
    #    break
    #end
    puts("DEBUG: INSIDE WHILE LOOP")
    fence_tried+=1
    sleep fence_retry_wait
    #STDOUT.flush
    
end
puts "DEBUG: AFTER WHILE LOOP"
    


# Loop through all vms
vms = VirtualMachinePool.new(client)
rc = vms.info_all
exit -1 if OpenNebula.is_error?(rc)


state = "STATE=3"
state += " or STATE=5" if force == "y"

vm_ids_array = vms.retrieve_elements("/VM_POOL/VM[#{state}]/HISTORY_RECORDS/HISTORY[HOSTNAME=\"#{host_name}\" and last()]/../../ID")

if vm_ids_array
    vm_ids_array.each do |vm_id|
        vm=OpenNebula::VirtualMachine.new_with_id(vm_id, client)
        vm.info

        if mode == "-r"
            vm.delete(true)
        elsif mode == "-d"
            vm.delete
        elsif mode == "-m"
            vm.resched
        end
    end
end

