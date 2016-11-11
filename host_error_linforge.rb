#!/usr/bin/env ruby

# -------------------------------------------------------------------------- #
# Copyright 2002-2015, OpenNebula Project (OpenNebula.org), C12G Labs        #
# Copyright 2016, LINFORGE Technologies GmbH (www.linforge.com)              #
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

# needed for executing shell commands
require "CommandManager"

# for debugging
require 'pp'

# logging to syslog
require 'syslog'

def slog(message)
    Syslog.open("ONE "+$0.split("/").last,Syslog::LOG_PID|Syslog::LOG_CONS) { |s| s.notice message }
end

if !(host_id=ARGV[0])
    exit -1
end

# we're getting IPMI credentials from $TEMPLATE (see host failure configuration in oned.conf)
if !(host_template=ARGV[1])
	exit -1
end

mode   = "-r" # By default, recreate VMs
#force  = "n"  # By default, don't recreate/delete suspended VMs
force  = "false"  # false in 5.2 script
#repeat = nil  #Â By default, don't wait for monitorization cycles"
repeat = 2  # new default in ONE 5.2 script

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

################################################################################
# Main
################################################################################

begin
    client = Client.new()
rescue Exception => e
    puts "Error: #{e}"
    exit -1
end

sys  = OpenNebula::System.new(client)
conf = sys.get_configuration

# Retrieve hostname
host  =  OpenNebula::Host.new_with_id(host_id, client)
rc = host.info
exit -1 if OpenNebula.is_error?(rc)
host_name = host.name

slog("#{host_name}(#{host_id}) NOTICE: host hook launched")

# Retrieve host monitor interval
begin
    MONITORING_INTERVAL = conf['MONITORING_INTERVAL'] || 60
rescue Exception => e
    slog("#{host_name}(#{host_id}) ERROR: Could not get MONITORING_INTERVAL")
    exit -1
end

# Retrieve ipmi data from host template (retrieve_elements returns array), if incomplete log error and exit 
ipmi_ip=host.retrieve_elements("//HOST/TEMPLATE/IPMI_IP")
ipmi_user=host.retrieve_elements("//HOST/TEMPLATE/IPMI_USER")
ipmi_pass=host.retrieve_elements("//HOST/TEMPLATE/IPMI_PASS")

if ipmi_ip == nil or ipmi_user == nil or ipmi_pass == nil
    slog("#{host_name}(#{host_id}) ERROR: node is about to be fenced, but ipmi data in host template is incomplete! ipmi_ip=#{ipmi_ip.to_s}, ipmi_user=#{ipmi_user.to_s}, ipmi_pass=#{ipmi_pass.to_s}")
    exit -1
else
    slog("#{host_name}(#{host_id}) WARNING: node is going to be fenced. ipmi_ip=#{ipmi_ip.to_s}, ipmi_user=#{ipmi_user.to_s}, ipmi_pass=#{ipmi_pass.to_s}")
    ipmi_ip=ipmi_ip[0].to_s
    ipmi_user=ipmi_user[0].to_s
    ipmi_pass=ipmi_pass[0].to_s
end

#xpath = "/VM_POOL/VM[#{state}]/HISTORY_RECORDS/HISTORY[HOSTNAME=\"#{host.name}\" and last()]"
#vm_ids_array = vms.retrieve_elements("#{xpath}/../../ID")

#### configure fencing START ######################
# which fence agent to use
fence_agent="/usr/sbin/fence_ipmilan"
# retry fence action this many times if unsucessful
fence_max_retries=3
# wait this many seconds between retries
fence_retry_wait=10
# onoff or cycle
fence_method="cycle"
# --power-wait (was -T), wait X seconds after on/off operation (Default Value: 2), set to 4 for HP iLO 3
fence_wait="4"
# --power-timeout (was -t), timeout (sec) for IPMI operation
fence_timeout="5"
#### configure fencing STOP #######################

# check wether fence_agent is installed
if !File.file?(fence_agent)
    slog("#{host_name}(#{host_id}) NOTICE: #{fence_agent} not installed, exiting!")
    exit -1
end

if repeat
    #Sleep through the desired number of monitor interval
    period = repeat * MONITORING_INTERVAL.to_i
    slog("#{host_name}(#{host_id}) NOTICE: waiting #{repeat} monitoring cycles (#{period} seconds total)")
    sleep(period)

    # If the host came back, log and exit! avoid duplicated VMs
    if host.state != 3 && host.state != 5
      slog("#{host_name}(#{host_id}) WARNING: node came back, fencing operation aborted!")
      exit 0 
    end
end

# the actual fencing command
# Ubuntu 14.04
fence_cmdline=fence_agent+" -a "+ipmi_ip+" -P -l "+ipmi_user+" -p "+ipmi_pass+" -o reboot -M "+fence_method+" -T "+fence_wait+" -t "+fence_timeout
# Ubuntu 16.04
#fence_cmdline=fence_agent+" -a "+ipmi_ip+" -P -l "+ipmi_user+" -p "+ipmi_pass+" -o reboot -m "+fence_method+" --power-wait="+fence_wait+" --power-timeout "+fence_timeout

slog("#{host_name}(#{host_id}) NOTICE: fencing cmd: #{fence_cmdline} ")
fence_cmd=LocalCommand.new(fence_cmdline)

# debug exit
#slog("#{host_name}(#{host_id}) WARNING: debug exit, host hook finished")
#exit 0

fence_try=0
while fence_try < fence_max_retries

    fence_cmd.run

    #Ubuntu 14.04 successful looks like this:
    #stdout was: Rebooting machine @ IPMI:148.198.181.11...Done#012, stderr was: ExitCode: 255

    if fence_cmd.stdout.include?("Rebooting") #&& fence_cmd.stderr.include?("Done")
        slog("#{host_name}(#{host_id}) NOTICE: node was fenced, stdout was: #{fence_cmd.stdout}, stderr was: #{fence_cmd.stderr}")
	# FIXME double check if host was definitely power cycled
        break
    else
        slog("#{host_name}(#{host_id}) ERROR: fencing not successful, stdout was: #{fence_cmd.stdout}, stderr was: #{fence_cmd.stderr}")
    end

    fence_try+=1
    sleep fence_retry_wait if fence_try < fence_max_retries
end

if fence_try == fence_max_retries
    slog("#{host_name}(#{host_id}) ERROR: tried fencing command "+fence_max_retries.to_s+" times, giving up! Please reboot machine manually, then reschedule VMs!")
    exit -1
end

# Loop through all vms
vms = VirtualMachinePool.new(client)
rc = vms.info_all
exit -1 if OpenNebula.is_error?(rc)

# STATE=3: ACTIVE (LCM unknown)
# STATE=5: SUSPENDED
# STATE=8: POWEROFF

state = "STATE=3"
state += " or STATE=5" if force == "y"

vm_ids_array = vms.retrieve_elements("/VM_POOL/VM[#{state}]/HISTORY_RECORDS/HISTORY[HOSTNAME=\"#{host_name}\" and last()]/../../ID")

if vm_ids_array
    vm_ids_array.each do |vm_id|
        vm=OpenNebula::VirtualMachine.new_with_id(vm_id, client)
        vm.info

        if mode == "-r"
	    slog("#{host_name}(#{host_id}) NOTICE: deleting VM #{vm_id.to_s}...")
            vm.delete(true)
        elsif mode == "-d"
	    slog("#{host_name}(#{host_id}) NOTICE: deleting VM #{vm_id.to_s}...")
            vm.delete
        elsif mode == "-m"
	    slog("#{host_name}(#{host_id}) NOTICE: rescheduling VM #{vm_id.to_s}...")
            vm.resched
	    # Recover with failure (0), success (1), retry (2), delete (3), delete-recreate (4)
	    slog("#{host_name}(#{host_id}) NOTICE: VM #{vm_id.to_s} lcm_state is #{vm.lcm_state}, status is #{vm.status}")
	    if vm.lcm_state == 16
	        slog("#{host_name}(#{host_id}) NOTICE: recovering VM #{vm_id.to_s}...")
	        #slog("#{host_name}(#{host_id}) NOTICE: please manually recover VM #{vm_id.to_s}...")
                vm.recover(0)
                sleep 5
                vm.recover(2)
            else
	        slog("#{host_name}(#{host_id}) NOTICE: won't recover VM #{vm_id.to_s}, please recover manually, lcm_state is #{vm.lcm_state}")
            end
        else
	    slog("#{host_name}(#{host_id}) ERROR: unknown mode '#{mode}'")
	    exit -1
        end
    end
else
    slog("#{host_name}(#{host_id}) NOTICE: no VMs found '#{mode}'")
end

slog("#{host_name}(#{host_id}) NOTICE: host hook finished")
exit 0
