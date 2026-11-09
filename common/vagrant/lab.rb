# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# lab.rb: the VM plumbing shared by every lab's Vagrantfile.
#
# A lab's Vagrantfile only describes what's specific to that lab and calls
# Lab.define. Everything else lives here, so every lab behaves the same way on
# every supported host:
#
#   Host                     Hypervisor (Vagrant provider)      Guest
#   macOS on Apple Silicon   VMware Fusion   (vmware_desktop)   Ubuntu 24.04 ARM64
#   Windows on x86-64        VirtualBox      (virtualbox)       Ubuntu 24.04 x86-64
#
# Lab.define(lab_dir, **lab) takes:
#   id:          folder name of the lab, e.g. "storefront-down"
#   level:       e.g. "Beginner" (shown in the login banner)
#   title:       the incident title
#   hostname:    the VM's hostname, e.g. "web-01"
#   host_octet:  last octet of the VM's address on the host-only network.
#                Every lab has its own, so labs can run side by side.
#   cpus:, memory: (MB)
#   web_port:    guest port that LAB_PORT_FORWARD forwards (default 80)
#   extra_disks: [{ name: "logs", size: "1GB" }, ...] extra blank disks.
#                VMware Fusion only. On VirtualBox, setup.sh must fall back to a
#                loop-file volume (see the storefront-down lab).
#
# Optional environment variables, read by `vagrant up` and `vagrant reload`:
#   LAB_GUI=1            open the VM's console window (useful if boot hangs)
#   LAB_PORT_FORWARD=1   also forward the web port to http://localhost:<8000 + host_octet>/
#                        (a fallback for when the host-only network doesn't work)

require "fileutils"

module Lab
  COMMON_DIR = File.expand_path("..", __dir__)
  BOX = "bento/ubuntu-24.04"

  # VirtualBox's default host-only network. On Windows it exists right after
  # VirtualBox is installed; Vagrant creates it if it doesn't.
  VBOX_SUBNET = "192.168.56"

  FUSION_NETWORKING = "/Library/Preferences/VMware Fusion/networking"
  VDISKMANAGER = "/Applications/VMware Fusion.app/Contents/Library/vmware-vdiskmanager"

  module_function

  # The one hypervisor and guest architecture this host is supported with.
  def platform
    if Vagrant::Util::Platform.darwin?
      { provider: "vmware_desktop", arch: "arm64", name: "VMware Fusion" }
    else
      { provider: "virtualbox", arch: "amd64", name: "VirtualBox" }
    end
  end

  def define(lab_dir, **lab)
    plat = platform
    ip = if plat[:provider] == "vmware_desktop"
           fusion_hostonly_ip(lab.fetch(:host_octet))
         else
           "#{VBOX_SUBNET}.#{lab.fetch(:host_octet)}"
         end
    gui = env_flag?("LAB_GUI")
    forward_port = 8000 + lab.fetch(:host_octet)

    Vagrant.configure("2") do |config|
      config.vm.box              = BOX
      config.vm.box_architecture = plat[:arch] # never fall back to another architecture
      config.vm.hostname         = lab.fetch(:hostname)
      config.vm.boot_timeout     = 600

      # A fixed address on the host-only network, reachable from your computer.
      # If Fusion's host-only network can't be found, fall back to DHCP; the
      # address is then shown by: vagrant ssh -c "cat /etc/lab/lab.env"
      if ip
        config.vm.network "private_network", ip: ip
      else
        config.vm.network "private_network", type: "dhcp"
      end
      if env_flag?("LAB_PORT_FORWARD")
        config.vm.network "forwarded_port", guest: lab.fetch(:web_port, 80), host: forward_port,
          host_ip: "127.0.0.1", auto_correct: true
      end

      message = ["#{lab.fetch(:id)} (#{lab.fetch(:hostname)}) is up on #{plat[:name]}."]
      message << "  Lab address: #{ip ? "http://#{ip}/" : %(run: vagrant ssh -c "cat /etc/lab/lab.env")}"
      message << "  Forwarded:   http://localhost:#{forward_port}/" if env_flag?("LAB_PORT_FORWARD")
      message << "  Next:        vagrant snapshot save broken   (first time only), then vagrant ssh"
      config.vm.post_up_message = message.join("\n")

      # Don't share the repo into the VM, because it contains the hints and solutions.
      config.vm.synced_folder ".", "/vagrant", disabled: true

      config.trigger.before :up do |t|
        t.name = "Check the hypervisor"
        t.ruby { |_env, machine| Lab.check_provider!(machine, plat) }
      end

      case plat[:provider]
      when "vmware_desktop" then vmware(config, lab_dir, lab, gui)
      when "virtualbox"     then virtualbox(config, lab, gui)
      end

      provision(config, lab_dir, lab, ip, plat)
    end
  end

  # Refuse hypervisors the labs don't support on this host, with a clear message
  # instead of a confusing failure halfway through `vagrant up`.
  def check_provider!(machine, plat)
    return if machine.provider_name.to_s == plat[:provider]

    raise Vagrant::Errors::VagrantError.new, <<~MSG.strip
      This lab runs on #{plat[:name]} on this computer, but Vagrant picked '#{machine.provider_name}'.
      Supported setups: macOS on Apple Silicon with VMware Fusion, or Windows with VirtualBox.
      Run `vagrant up --provider #{plat[:provider]}`, and check that VAGRANT_DEFAULT_PROVIDER isn't set.
    MSG
  end

  # --- VMware Fusion (macOS) ---------------------------------------------------

  def vmware(config, lab_dir, lab, gui)
    # Extra disks. Vagrant's experimental `config.vm.disk` crashes with the bento
    # box on Fusion (vagrant-vmware-desktop 3.0.5), so disks are managed here:
    # created with Fusion's vmware-vdiskmanager before `vagrant up`, attached on
    # the box's existing SATA controller (slot 0 = system disk, slot 1 = CD-ROM),
    # and deleted after `vagrant destroy`.
    disks = Array(lab[:extra_disks]).each_with_index.map do |d, i|
      { slot: "sata0:#{2 + i}", size: d.fetch(:size),
        file: File.join(lab_dir, ".vagrant", "#{lab.fetch(:id)}-#{d.fetch(:name)}.vmdk") }
    end

    unless disks.empty?
      config.trigger.before :up do |t|
        t.name = "Create extra disks"
        t.ruby { |_env, _machine| Lab.create_vmware_disks(disks) }
      end
      config.trigger.after :destroy do |t|
        t.name = "Delete extra disks"
        t.ruby { |_env, _machine| disks.each { |d| FileUtils.rm_f(d[:file]) } }
      end
    end

    config.vm.provider "vmware_desktop" do |vmware|
      vmware.cpus   = lab.fetch(:cpus)
      vmware.memory = lab.fetch(:memory)
      vmware.gui    = gui
      # The disk entries go into the VM's .vmx only when the VM is first
      # created. After a snapshot, VMware points them at delta files, and
      # re-applying them on every boot would make the VM write to the snapshot's
      # frozen base disk and break `vagrant snapshot restore`.
      unless vm_created?(lab_dir, "vmware_desktop")
        disks.each do |d|
          vmware.vmx["#{d[:slot]}.present"]  = "TRUE"
          vmware.vmx["#{d[:slot]}.filename"] = d[:file]
        end
      end
    end
  end

  def create_vmware_disks(disks)
    disks.each do |d|
      next if File.exist?(d[:file])

      FileUtils.mkdir_p(File.dirname(d[:file]))
      ok = system(VDISKMANAGER, "-c", "-s", d[:size], "-a", "lsilogic", "-t", "0", d[:file],
                  out: File::NULL)
      raise Vagrant::Errors::VagrantError.new, "Could not create #{d[:file]} with #{VDISKMANAGER}" unless ok
    end
  end

  # Since macOS Big Sur, Fusion can't create host-only networks with custom
  # subnets: Vagrant fails with "Failed to enable device". So instead of a made-up
  # subnet, reuse the host-only network Fusion already has (normally vmnet1) and
  # take a fixed address on it. The subnet is chosen randomly when Fusion is
  # installed, so it differs from Mac to Mac.
  def fusion_hostonly_ip(host_octet)
    return nil unless File.readable?(FUSION_NETWORKING)

    vnets = Hash.new { |h, k| h[k] = {} }
    File.foreach(FUSION_NETWORKING) do |line|
      next unless (m = line.match(/^answer VNET_(\d+)_(\S+)\s+(\S+)/))

      vnets[m[1]][m[2]] = m[3]
    end
    # Fusion's own host-only networks have DHCP and no NAT. (Networks that
    # Vagrant tried and failed to create have no DHCP, so they're skipped.)
    usable = vnets.select do |_, v|
      v["HOSTONLY_SUBNET"] && v["HOSTONLY_NETMASK"] == "255.255.255.0" &&
        v["DHCP"] == "yes" && v["NAT"] != "yes"
    end
    _, vnet = usable.min_by { |num, _| num == "1" ? 0 : num.to_i }
    return nil unless vnet

    vnet["HOSTONLY_SUBNET"].split(".")[0, 3].push(host_octet).join(".")
  end

  # --- VirtualBox (Windows) ------------------------------------------------------

  def virtualbox(config, lab, gui)
    config.vm.provider "virtualbox" do |vb|
      vb.cpus   = lab.fetch(:cpus)
      vb.memory = lab.fetch(:memory)
      vb.gui    = gui
    end
  end

  # --- Provisioning: helpers -> common base -> healthy setup -> break -----------
  # Runs once, on the first `vagrant up`. To reset a lab, restore the snapshot
  # or destroy and re-create the VM. Don't run `vagrant provision`.

  def provision(config, lab_dir, lab, ip, plat)
    config.vm.provision "upload-lib", type: "file",
      source: File.join(COMMON_DIR, "lib", "lab-common.sh"), destination: "/tmp/lab-common.sh"
    config.vm.provision "upload-check", type: "file",
      source: File.join(lab_dir, "check.sh"), destination: "/tmp/lab-check"
    config.vm.provision "upload-ticket", type: "file",
      source: File.join(lab_dir, "TICKET.md"), destination: "/tmp/lab-ticket.md"

    config.vm.provision "base", type: "shell", path: File.join(COMMON_DIR, "provision", "base.sh"),
      env: { "LAB_ID" => lab.fetch(:id), "LAB_LEVEL" => lab.fetch(:level), "LAB_TITLE" => lab.fetch(:title),
             "LAB_IP" => ip || "auto", "LAB_ARCH" => plat[:arch] }
    config.vm.provision "setup", type: "shell", path: File.join(lab_dir, "provision", "setup.sh")
    config.vm.provision "break", type: "shell", path: File.join(lab_dir, "provision", "break.sh")
  end

  # --- Helpers ---------------------------------------------------------------------

  def env_flag?(name)
    %w[1 true yes on].include?(ENV[name].to_s.strip.downcase)
  end

  def vm_created?(lab_dir, provider)
    id_file = File.join(lab_dir, ".vagrant", "machines", "default", provider, "id")
    File.exist?(id_file) && File.exist?(File.read(id_file).strip)
  end
end
