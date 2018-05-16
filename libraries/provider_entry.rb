#
# Cookbook Name:: ldap
# Provider:: entry
#
# Copyright 2014 Riot Games, Inc.
# Author:: Alan Willis <alwillis@riotgames.com>
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

require 'chef/provider/lwrp_base'

class Chef
  class Provider
    class LdapEntry < Chef::Provider::LWRPBase


provides :ldap_entry
def whyrun_supported?
  true
end

action :create do

  require 'cicphash'

  @current_resource = load_current_resource

  # LDAP instances are not case sensitive
  @new_resource.attributes.keys.each do |k|
    @new_resource.attributes[k.downcase.to_s] = @new_resource.attributes.delete(k)
  end

  converge_by("Entry #{@new_resource.distinguished_name}") do

    ldap = Chef::Ldap.new
    @connectinfo = load_connection_info

    new_attributes = CICPHash.new.merge(@new_resource.attributes.to_hash)
    seed_attributes = CICPHash.new.merge(@new_resource.seed_attributes.to_hash)
    append_attributes = CICPHash.new.merge(@new_resource.append_attributes.to_hash)

    if @current_resource.nil?
      Chef::Log.info("Adding #{@new_resource.distinguished_name}")
      new_attributes.merge!(seed_attributes)
      new_attributes.merge!(append_attributes)
      ldap.add_entry(@connectinfo, @new_resource.distinguished_name, new_attributes)
      new_resource.updated_by_last_action(true)
    else

      seed_attribute_names = seed_attributes.keys.map{ |k| k.downcase.to_s }
      current_attribute_names = @current_resource.attributes.keys.map{ |k| k.downcase.to_s }

      # Include seed attributes in with the normal attributes 
      ( seed_attribute_names - current_attribute_names ).each do |attr|
        value = seed_attributes[attr].is_a?(String) ? [ seed_attributes[attr] ] : seed_attributes[attr]
        new_attributes.merge!({ attr => value })
      end

      all_attributes = new_attributes.merge(append_attributes)
      all_attribute_names = all_attributes.keys.map{ |k| k.downcase.to_s }

      # Prune unwanted attributes and/or values
      prune_keys = Array.new

      prune_whole_attributes = @new_resource.prune.kind_of?(Array) ? @new_resource.prune.map{ |k| k.to_s } : []
      prune_attribute_values = @new_resource.prune.kind_of?(Hash) ? @new_resource.prune.to_hash : {}

      prune_whole_attributes.each do |attr|
        all_attributes.delete(attr)
        all_attribute_names.reject{ |name| name == attr }
        next unless @current_resource.attributes.key?(attr)
        prune_keys.push([ :delete, attr, nil ])
      end

      prune_attribute_values.each do |attr,values|
        values = values.kind_of?(String) ? [ values ] : values
        all_attributes[attr] = all_attributes[attr].kind_of?(String) ? [ all_attributes[attr] ] : all_attributes[attr]
        shred = ( all_attributes[attr] & values )
        all_attributes[attr] -= shred
        values -= shred

        if all_attributes[attr].size == 0
          all_attribute_names.reject{ |name| name == attr }
          all_attributes.delete(attr)
        end

        next unless @current_resource.attributes.key?(attr)
        values = ( values & @current_resource.attributes[attr] )
        prune_keys.push([ :delete, attr, values ]) if values.size > 0
      end

      # Add keys that are missing
      add_keys = Array.new

      ( all_attribute_names - current_attribute_names ).each do |attr|
        add_values = attr.is_a?(String) ? [ all_attributes[attr] ] : all_attributes[attr]
        add_keys.push([ :add, attr, add_values ])
      end

      # Update existing keys, append values if necessary
      update_keys = Array.new

      ( all_attribute_names & current_attribute_names ).each do |attr|

        # Ignore Distinguished Name (DN) and the Relative DN. 
        # These should only be modified upon entry creation to avoid schema violations
        relative_distinguished_name = @new_resource.distinguished_name.split('=').first

        next if attr =~ /DN/i || attr == relative_distinguished_name 

        if append_attributes[attr]

          append_values = append_attributes[attr].is_a?(String) ? [ append_attributes[attr] ] : append_attributes[attr]
          append_values -= @current_resource.attributes[attr]

          if append_values.size > 0 
            update_keys.push([ :add, attr, append_values ])
          end
        end

        if new_attributes[attr]

          replace_values = new_attributes[attr].is_a?(String) ? [ new_attributes[attr] ] : new_attributes[attr]
          if ( replace_values.size > 0 ) and ( replace_values.sort != @current_resource.attributes[attr].sort )
            update_keys.push([ :replace, attr, replace_values ])
          end
        end
      end

      # Modify entry if there are any changes to be made
      if ( add_keys | update_keys | prune_keys ).size > 0
        # Submit one set of operations at a time, easier to debug

        if add_keys.size > 0
          Chef::Log.info("Add #{@new_resource.distinguished_name} #{ add_keys }")
          ldap.modify_entry(@connectinfo, @new_resource.distinguished_name, add_keys)
        end

        if update_keys.size > 0
          Chef::Log.info("Update #{@new_resource.distinguished_name} #{update_keys}")
          ldap.modify_entry(@connectinfo, @new_resource.distinguished_name, update_keys)
        end

        if prune_keys.size > 0
          Chef::Log.info("Delete #{@new_resource.distinguished_name} #{prune_keys}")
          ldap.modify_entry(@connectinfo, @new_resource.distinguished_name, prune_keys)
        end

        new_resource.updated_by_last_action(true)
      end
    end
  end
end

action :delete do

  @current_resource = load_current_resource

  if @current_resource
    converge_by("Removing #{@current_resource.distinguished_name}") do
      ldap = Chef::Ldap.new
      @connectinfo = load_connection_info
      ldap.delete_entry(@connectinfo, @current_resource.distinguished_name)
    end
  end
end

def load_current_resource
  ldap = Chef::Ldap.new
  @connectinfo = load_connection_info
  entry = ldap.get_entry(@connectinfo, @new_resource.distinguished_name)
  
  if entry
    @current_resource = Chef::Resource::LdapEntry.new entry.dn
    
    ihash={}
    entry.attribute_names.each do |key|
      ihash[key.to_s] = entry[key]
    end
    @current_resource.attributes = ihash
  end
  
  @current_resource
end

def load_connection_info

  @connectinfo = Hash.new
  @connectinfo.class.module_eval { attr_accessor :host, :port, :credentials, :databag_name, :use_tls }
  @connectinfo.host = new_resource.host
  @connectinfo.port = new_resource.port
  @connectinfo.credentials = new_resource.credentials
  # default databag name is cookbook name
  databag_name = new_resource.databag_name.nil? ? new_resource.cookbook_name : new_resource.databag_name
  @connectinfo.databag_name = databag_name
  @connectinfo.use_tls = new_resource.use_tls
  @connectinfo
end

end
end
end
