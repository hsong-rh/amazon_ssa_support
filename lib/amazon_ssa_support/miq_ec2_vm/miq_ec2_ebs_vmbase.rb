require_relative 'miq_ec2_vmbase'
require_relative '../instance_metadata'

module AmazonSsaSupport
  class MiqEC2EbsVmBase < MiqEC2VmBase
    attr_reader :volumes

    def initialize(ec2_obj, host_instance, ec2)
      super
      @block_device_keys = ebs_ids
      @volumes           = []
      @miq_vm            = nil
    end

    def ebs_instance?
      @ec2_obj.respond_to?(:instance_id) ? true : false
    end

    def ebs_image?
      @ec2_obj.respond_to?(:instance_id) ? false : true
    end

    def extract(cat)
      miq_vm.extract(cat)
    end

    def unmount
      @miq_vm.unmount unless @miq_vm.nil?
      unmap_volumes
    end

    def ebs_ids
      ids = []
      if ebs_instance?
        @ec2_obj.block_device_mappings.each do |dev|
          ids << dev.ebs.volume_id
        end
      else
        @ec2_obj.block_device_mappings.each do |dev|
          ids << dev.ebs.snapshot_id
        end
      end
      ids
    end

    def zone_name
      aim = InstanceMetadata.new
      aim.metadata('placement/availability-zone')
    end

    def miq_vm
      return @miq_vm unless @miq_vm.nil?

      raise "#{self.class.name}.miq_vm: could not map volumes" unless map_volumes
      `ls -l /dev/xvd*`.each_line { |l| _log.debug("        #{l.chomp}") } if _log.debug?
      cfg = create_cfg
      cfg.each_line { |l| _log.debug("    #{l.chomp}") } if _log.debug?

      @miq_vm = MiqVm.new(cfg)
    end

    def create_cfg
      diskid = 'scsi0:0'
      mapdev = File.exists?('/host/dev/xvdf') ? '/host/dev/xvdf' : '/dev/xvdf'
      hardware = ''
      @block_device_keys.each do
        hardware += "#{diskid}.present = \"TRUE\"\n"
        hardware += "#{diskid}.filename = \"#{mapdev}\"\n"
        diskid.succ!
        mapdev.succ!
      end
      hardware
    end

    def create_snapshot(vol_id)
      return vol_id if ebs_image?

      _log.info("    Creating snapshot of instance volume #{vol_id}")
      snap = @ec2.create_snapshot(volume_id: vol_id, description: "SSA extract snapshot for instance: #{@ec2_obj.id}")
      snap.wait_until_completed
      snap.create_tags(tags: [{key: 'Name', value: 'SSA extract snapshot'}])
      _log.info("    Snapshot #{snap.id} of instance volume #{vol_id} is created!")
      @snapshots << snap
      snap
    end

    def create_volume(snap_id)
      _log.info("    Creating volume based on #{snap_id}")
      snap = @ec2.snapshot(snap_id)
      if snap.nil?
        _log.warn("    Snapshot #{snap_id} does not exist (nil)")
        return nil
      end
      volume = @ec2.create_volume(snapshot_id: snap_id, availability_zone: zone_name)
      sleep 2
      @ec2.client.wait_until(:volume_available, volume_ids: [volume.id])

      volume.create_tags(tags: [{ key: 'Name', value: 'SSA extract volume'},
                                { key: 'Description', value: "SSA extract volume for image: #{@ec2_obj.id}"}])

      _log.info("    Volume #{volume.id} of snapshot #{snap_id} is created!")
      @volumes << volume

      volume
    end

    def map_volumes(mapdev = '/dev/xvdf')
      @block_device_keys.each do |k|
        vol = create_volume(k)
        return false if vol.nil?
        _log.info("    Attaching volume #{vol.id} to #{mapdev}")
        vol.attach_to_instance(instance_id: @host_instance.id, device: mapdev)
        sleep 5
        @ec2.client.wait_until(:volume_in_use, volume_ids: [vol.id])
        _log.info("    Volume #{vol.id} is attached!")
        mapdev.succ!
      end
      true
    end

    def unmap_volumes
      while (vol = @volumes.shift)
        attachment = vol.detach_from_instance(instance_id: @host_instance.id, force: true)

        _log.debug("#{vol.id} is #{attachment.state}")
        @ec2.client.wait_until(:volume_available, volume_ids: [vol.id])
        vol.delete
        @ec2.client.wait_until(:volume_deleted, volume_ids: [vol.id])
        _log.debug("Volume #{vol.inspect} is deleted!")
      end

      while (snap = @snapshots.shift)
        snap.delete
      end
    end
  end
end
