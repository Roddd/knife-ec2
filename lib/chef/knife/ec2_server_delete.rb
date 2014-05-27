#
# Author:: Adam Jacob (<adam@opscode.com>)
# Author:: Seth Chisamore (<schisamo@opscode.com>)
# Copyright:: Copyright (c) 2009-2011 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/knife/ec2_base'

# These two are needed for the '--purge' deletion case
require 'chef/node'
require 'chef/api_client'

class Chef
  class Knife
    class Ec2ServerDelete < Knife

      include Knife::Ec2Base

      banner "knife ec2 server delete SERVER [SERVER] (options)"

      attr_reader :server

      option :purge,
        :short => "-P",
        :long => "--purge",
        :boolean => true,
        :default => false,
        :description => "Destroy corresponding node and client on the Chef Server, in addition to destroying the EC2 node itself.  Assumes node and client have the same name as the server (if not, add the '--node-name' option)."

      option :chef_node_name,
        :short => "-N NAME",
        :long => "--node-name NAME",
        :description => "The name of the node and client to delete, if it differs from the server name.  Only has meaning when used with the '--purge' option."

      option :release_eip,
        :short => "-R",
        :long => "--release-eip",
        :boolean => true,
        :default => false,
        :description => "Release the attached Elastic IP Address during termination."

      # Extracted from Chef::Knife.delete_object, because it has a
      # confirmation step built in... By specifying the '--purge'
      # flag (and also explicitly confirming the server destruction!)
      # the user is already making their intent known.  It is not
      # necessary to make them confirm two more times.
      def destroy_item(klass, name, type_name)
        begin
          object = klass.load(name)
          object.destroy
          ui.warn("Deleted #{type_name} #{name}")
        rescue Net::HTTPServerException
          ui.warn("Could not find a #{type_name} named #{name} to delete!")
        end
      end

      def release_eip(ip_address)
        begin
          ui.info("Searching for EIP: #{ip_address}")
          eip = connection.addresses.get(ip_address)

          # Disassociating EIP's in vpc requires public_ip to be nil
          public_ip = eip.domain == "vpc" ? nil : eip.public_ip

          confirm("Do you really want to release the Elastic IP \"#{ip_address}\" with allocation_id \"#{eip.allocation_id}\"")

          # Check to ensure we are not allocated, or allocated to this server
          unless eip.server_id == nil or eip.server_id == @server.id
            ui.error("Server id \"#{eip.server_id}\" is associated with this elastic ip. We cannot delete it.")
            exit 1
          end
          association_id = eip.association_id.nil? ? nil : eip.association_id
          connection.disassociate_address(public_ip, association_id)
          ui.info("Waiting for Elastic IP to Disassociate")
          eip.wait_for { print '.'; server_id == nil }
          puts
          eip.destroy

          ui.warn("Released Elastic IP #{ip_address}")

        rescue Fog::Compute::AWS::Error => e
          ui.error("Failed to release elastic IP: #{e.message}")
          return false
        end
      end

      def run

        validate!

        @name_args.each do |instance_id|

          begin
            @server = connection.servers.get(instance_id)

            msg_pair("Instance ID", @server.id)
            msg_pair("Flavor", @server.flavor_id)
            msg_pair("Image", @server.image_id)
            msg_pair("Region", connection.instance_variable_get(:@region))
            msg_pair("Availability Zone", @server.availability_zone)
            msg_pair("Security Groups", @server.groups.join(", "))
            msg_pair("SSH Key", @server.key_name)
            msg_pair("Root Device Type", @server.root_device_type)
            msg_pair("Public DNS Name", @server.dns_name)
            msg_pair("Public IP Address", @server.public_ip_address)
            msg_pair("Private DNS Name", @server.private_dns_name)
            msg_pair("Private IP Address", @server.private_ip_address)

            puts "\n"
            confirm("Do you really want to delete this server")

            # Release the Elastic IP if it's asked of us
            if config[:release_eip] and @server.public_ip_address != nil
              release_eip(@server.public_ip_address)
            else
              ui.warn("Elastic IP address not released.") unless @server.public_ip_address.nil?
            end

            @server.destroy

            ui.warn("Deleted server #{@server.id}")

            if config[:purge]
              thing_to_delete = config[:chef_node_name] || instance_id
              destroy_item(Chef::Node, thing_to_delete, "node")
              destroy_item(Chef::ApiClient, thing_to_delete, "client")
            else
              ui.warn("Corresponding node and client for the #{instance_id} server were not deleted and remain registered with the Chef Server")
            end

          rescue NoMethodError => e
            ui.error("Error while trying to delete'#{instance_id}': #{e}")
          end
        end
      end

    end
  end
end
