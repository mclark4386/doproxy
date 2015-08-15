#!/usr/bin/ruby

require 'droplet_kit'
require 'erb'
require 'fileutils'
require 'yaml'

class DOProxy
  def initialize
    config = YAML::load(File.open('doproxy.yml'))
    @ssh_key_ids = []
    config['ssh_key_ids'].each do |key|
      @ssh_key_ids.push(key)
    end
    @inventory_file = config['inventory_file']
    @userdata_file = config['userdata_file']
    @haproxy_template_file = config['haproxy_template_file']
    @haproxy_cfg_file = config['haproxy_cfg_file']
    @haproxy_cfg_path = config['haproxy_cfg_path']
    @hostname_prefix = config['droplet_options']['hostname_prefix']
    @region = config['droplet_options']['region']
    @size = config['droplet_options']['size']
    @image = config['droplet_options']['image']
    @master = config['droplet_options']['master']
    @clone_image = config['droplet_options']['clone_image']
    @snapshot_overwrite = config['droplet_options']['snapshot_overwrite']

    @client = DropletKit::Client.new(access_token: config['token'])
    @backend_count
    @droplets = []

    get_inventory
  end

  def get_inventory
    if File.exist?(@inventory_file) == false
      raise "Inventory file doesn't exist! Create one."
    else
      @backend_count = 0
      backend_inventory = File.open(@inventory_file).read
      backend_inventory.each_line do |droplet_id|
        droplet = @client.droplets.find(id: droplet_id)
        if droplet == '{"id":"not_found","message":"The resource you were accessing could not be found."}'
          raise "Inventory file contains a non-existent droplet id (#{droplet.id})!"
        else
          @droplets << droplet
          @backend_count += 1
        end
      end
    end
  end

  def print_inventory
    if @backend_count == 0
      puts "The inventory file is empty. Use the create command.\n"
    else
      @droplets.each_with_index do |droplet, index|
        puts "#{index}) #{droplet.name}  (pvt ip: #{droplet.private_ip}, status: #{droplet.status}, id: #{droplet.id})"
      end
    end
  end

  def create_server
    hostname = "#{@hostname_prefix}-#{@backend_count}"
    userdata = File.open(@userdata_file).read
    droplet = DropletKit::Droplet.new(name: hostname, region: @region, size: @size, image: @image, private_networking: true, ssh_keys: @ssh_key_ids, user_data: userdata)
    created = @client.droplets.create(droplet)
    droplet_id = created.id

    if (created.status == 'new')
      while created.status != 'active'
        sleep(15)  # wait for droplet to become active before checking again
        created = @client.droplets.find(id: droplet_id)
      end
      # droplet status is now 'active'
      backend_inventory = File.open(@inventory_file, 'a')
      backend_inventory.write("#{droplet_id}\n")
      backend_inventory.close
      @backend_count += 1
      @droplets.push(created) # add droplet to array so it gets included in haproxy.cfg
      reload_haproxy
      puts "Success: #{droplet_id} created and added to backend."
    else
      puts "Some error has occurred on droplet create (status was not 'new')"
    end
  end

  def delete_server(line_number)
    if line_number > @backend_count-1 || line_number < 0
      raise "Specified line does not exist in inventory! (line_number)"
    else
      droplet_id = @droplets[line_number].id
      output_file = "#{@inventory_file}.tmp"
      line_position = 0
      File.open(output_file, 'w') do |output|
        File.foreach(@inventory_file) do |line|
          if line_position != line_number
            output.puts(line)
          end
          line_position += 1
        end
      end
      FileUtils.mv(output_file, @inventory_file)
      @droplets.delete_at(line_number) # remove droplet from array so it doesn't get included in haproxy.cfg
      reload_haproxy
      @client.droplets.delete(id: droplet_id)
      @backend_count -= 1
      puts "Success: #{droplet_id} deleted and removed from backend."
    end
  end

  def generate_haproxy_cfg
    template = File.open(@haproxy_template_file).read
    renderer = ERB.new(template, nil, '-')

    output = File.open(@haproxy_cfg_file, 'w+')
    output.write(renderer.result(binding))
    output.close
  end

  def reload_haproxy
    generate_haproxy_cfg
    FileUtils.cp(@haproxy_cfg_file, "#{@haproxy_cfg_path}/#{@haproxy_cfg_file}")
    `service haproxy reload`
  end

  def clone_server
    hostname = "#{@hostname_prefix}-#{@backend_count}"
    userdata = File.open(@userdata_file).read

    mdrop = nil

    @client.droplets.all.each do |droplet|
      if droplet.name == @master
        puts droplet.id
        mdrop = droplet
      end
    end

    if mdrop.nil?
      puts "@master=|"+@master+"|"
      puts "Could not find master droplet"
      return
    end

    image = imageWithName(@clone_image)

    if image.nil? or @snapshot_overwrite
      puts "Shutting down master.."
      shutdown = @client.droplet_actions.shutdown(droplet_id: mdrop.id)

      if shutdown 
        if shutdown.try( :status )
          while shutdown.status != "completed"
            puts ".."
            sleep(2)
            shutdown = @client.actions.find(id: shutdown.id)
          end
        else 
          if shutdown['id']
            if shutdown['id'] == 'unprocessable_entity'
              puts shutdown.message
            end
          else
            puts "Not sure what happened, but here is the response:"+shutdown
            return
          end
        end
      else
        puts "Not sure what happend, but no response from trying to shutdown the master"
        return
      end

      puts "Creating snapshot.."
      snapshot = @client.droplet_actions.snapshot(droplet_id: mdrop.id, name: @clone_image) 

      if snapshot.try( :id ) and snapshot.id == 'unprocessable_entity'
        puts snapshot.message
        return
      end


      if snapshot and snapshot.try( :status )
        while snapshot.status != "completed"
          puts ".."
          sleep(2)
          snapshot = @client.actions.find(id: snapshot.id)
        end
      else
        puts "Not sure what happened, but here is the response:"+snapshot
        return
      end

      @client.droplet_actions.power_on(droplet_id: mdrop.id)

      image = imageWithName(@clone_image)
    end

    if image.nil?
      puts "Image was not created"
      return
    end

    puts "Creating Droplet from snapshot.."
    
    droplet = DropletKit::Droplet.new(name: hostname, region: @region, size: @size, image: image.id, private_networking: true, ssh_keys: @ssh_key_ids, user_data: userdata)
    created = @client.droplets.create(droplet)
    droplet_id = created.id

    if (created.status == 'new')
      while created.status != 'active'
        sleep(15)  # wait for droplet to become active before checking again
        created = @client.droplets.find(id: droplet_id)
      end
      # droplet status is now 'active'
      backend_inventory = File.open(@inventory_file, 'a')
      backend_inventory.write("#{droplet_id}\n")
      backend_inventory.close
      @backend_count += 1
      @droplets.push(created) # add droplet to array so it gets included in haproxy.cfg
      reload_haproxy
      puts "Success: #{droplet_id} created and added to backend."
    else
      puts "Some error has occurred on droplet create (status was not 'new')"
    end    
  end

  def imageWithName(name)
    @client.images.all(public: false).each do |image|
      if image.name == name
        return image
      end
    end
    return nil
  end

end

def print_usage
  puts "Commands:"
  puts "#{$0} print                   # Print backend droplets in inventory file"
  puts "#{$0} create                  # Create a new backend droplet and reload"
  puts "#{$0} delete <LINE_NUMBER>    # Delete a droplet and reload"
  puts "#{$0} reload                  # Generate HAProxy config and reload HAProxy"
  puts "#{$0} generate                # Generate HAProxy config based on inventory"
end


if ARGV[0] == nil
  print_usage
else
  proxy = DOProxy.new

  case ARGV[0]
  when "print"
    proxy.print_inventory
  when "create"
    proxy.create_server
  when "clone"
    proxy.clone_server
  when "delete"
    if ARGV[1] != nil
      proxy.delete_server(ARGV[1].to_i)
    else
      puts "Specify which droplet to delete!"
    end
  when "reload"
    proxy.reload_haproxy
  when "generate"
    proxy.generate_haproxy_cfg
  end
end
