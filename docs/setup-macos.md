# Setting up an Apple Silicon Mac for the labs

On a Mac the labs run on **VMware Fusion**, and the lab VMs are ARM64. You
install the following once. All of it runs natively on Apple Silicon, so nothing
is emulated. (VirtualBox isn't supported on macOS. On Windows, see
[setup-windows.md](setup-windows.md).)

| Component                       | What it does                                                                  | Install method           |
| ------------------------------- | ----------------------------------------------------------------------------- | ------------------------ |
| Homebrew                        | macOS package manager                                                         | install script           |
| VMware Fusion                   | the hypervisor that runs the VMs                                              | Broadcom download (free) |
| Vagrant ≥ 2.4                   | builds and manages the VMs from a `Vagrantfile`                               | Homebrew                 |
| Vagrant VMware Utility          | small root service that lets Vagrant drive Fusion (networking, port forwards) | Homebrew                 |
| `vagrant-vmware-desktop` plugin | Vagrant's VMware provider                                                     | `vagrant plugin install` |

Plan on about 6 GB of free disk space per lab you keep: the VM, its disks,
and a snapshot (which includes the VM's 1.5–2 GB of RAM). The base box needs
about 1 GB more, once.

> **Install order matters.** Install VMware Fusion **before** the Vagrant VMware
> Utility. The utility checks for Fusion when it starts.

---

## 1. Homebrew

Skip this if `brew --version` already works.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Put brew on your PATH (Apple Silicon installs to /opt/homebrew)
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"

brew --version
```

## 2. VMware Fusion

Fusion Pro is free. Since Broadcom bought VMware it's downloaded from the
Broadcom support portal, and Homebrew no longer has a cask for it.

1. Create a free Broadcom account at <https://profile.broadcom.com/web/registration>.
2. Sign in at <https://support.broadcom.com/group/ecx/productdownloads?subfamily=VMware%20Fusion&freeDownloads=true>, open **My Downloads**, and search
   for **VMware Fusion**. Pick the newest release (25H2 or later at the time of
   writing; 13.6.x also works), accept the terms, and download the `.dmg`.
   Broadcom moves this page around now and then. If you can't find it, search
   the web for "download VMware Fusion free Broadcom".
3. Open the `.dmg` and run the installer. Then **launch Fusion once**:
   - enter your admin password when it asks to install its helpers
   - if it asks about a license, choose the free / personal-use option
   - if macOS blocks a component, allow it under
     **System Settings → Privacy & Security** and start Fusion again
4. Quit Fusion. Vagrant runs it headless from now on.

Check it's installed:

```bash
ls "/Applications/VMware Fusion.app" && \
  "/Applications/VMware Fusion.app/Contents/Library/vmrun" | head -1
```

## 3. Vagrant

HashiCorp publishes Vagrant through its own Homebrew tap:

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/hashicorp-vagrant
# (The community cask also works: brew install --cask vagrant)

vagrant --version        # needs 2.4.0 or newer
```

## 4. Vagrant VMware Utility

```bash
brew install --cask vagrant-vmware-utility
```

The installer registers a launchd service that starts automatically. You only
need to restart it if you installed Fusion _after_ the utility, or if Vagrant
reports it can't talk to it:

```bash
sudo launchctl unload -w /Library/LaunchDaemons/com.vagrant.vagrant-vmware-utility.plist
sudo launchctl load   -w /Library/LaunchDaemons/com.vagrant.vagrant-vmware-utility.plist
```

## 5. The VMware provider plugin

```bash
vagrant plugin install vagrant-vmware-desktop
vagrant plugin list      # expect: vagrant-vmware-desktop (3.x.y, global)
```

Run `vagrant plugin update` now and then, especially after upgrading Fusion or
Vagrant.

## 6. Optional: pre-download the base box

`vagrant up` downloads the box automatically, but you can fetch it ahead of time
(about 1 GB):

```bash
vagrant box add bento/ubuntu-24.04 --provider vmware_desktop --architecture arm64
vagrant box list         # expect: bento/ubuntu-24.04 (vmware_desktop, <version>, (arm64))
```

## 7. Smoke test

```bash
git clone https://github.com/tajpouria/linux-troubleshooting-labs.git
cd linux-troubleshooting-labs/labs/beginner/storefront-down
vagrant up
vagrant ssh -c "uname -m"    # expect: aarch64
```

`uname -m` should print `aarch64`. Anything else means you got the wrong box
architecture.

---

## Troubleshooting the toolchain

| Symptom                                                                                          | Fix                                                                                                                                                                        |
| ------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Vagrant encountered an error while attempting to connect to the Vagrant VMware Utility service` | Restart the utility (step 4). If Fusion was installed afterwards, restarting is required.                                                                                  |
| `The provider 'vmware_desktop' could not be found`                                               | Install the plugin (step 5) and check that `vagrant plugin list` shows it.                                                                                                 |
| `The box 'bento/ubuntu-24.04' could not be found` or no matching architecture                    | Make sure `vagrant --version` is ≥ 2.4 and you're online. Try step 6 explicitly with `--architecture arm64`.                                                               |
| `vagrant up` hangs at "Waiting for the VM to receive an address" or times out                    | Run `LAB_GUI=1 vagrant reload` to watch the console. Make sure Fusion isn't waiting on a dialog. Restart the utility.                 |
| `Vagrant failed to create a new VMware networking device` / `Failed to enable device` | Fusion on macOS Big Sur and later can't create host-only networks with custom subnets. The labs avoid this by reusing Fusion's own host-only network (see `common/vagrant/lab.rb`). If you still see it, run `vagrant destroy -f`, then clean up the half-created network (see [below](#cleaning-up-a-failed-host-only-network)) and run `vagrant up` again. |
| The site isn't reachable at `http://<LAB_IP>/` _before_ you've started fixing things | That's expected. The lab is broken on purpose. To test the network path itself, `ping <LAB_IP>` from the Mac. If ping fails too, check that Fusion's host-only bridge is up with `ifconfig bridge100`. As a last resort, run `LAB_PORT_FORWARD=1 vagrant reload` and use `http://localhost:80NN/` (8000 + the lab's host octet, e.g. 8011). |
| `lsblk` in the VM shows no extra 1 GB disk, and `vagrant up` printed "using a 1 GB loop-file volume"  | The extra disk wasn't attached. The lab still works the same way. To get the real disk, run `vagrant destroy -f`, then `vagrant up`, and check that it prints "Running trigger: Create extra disks". |
| `no implicit conversion of nil into String` from `vagrant-vmware-desktop/cap/disk.rb` | A bug in the plugin's experimental `config.vm.disk` support with the bento box. The labs don't use that feature, so make sure your copy is up to date. |
| You locked yourself out of SSH (for example with a firewall rule)                                | Run `LAB_GUI=1 vagrant reload` and log in on the console as `vagrant` / `vagrant`. Or restore your snapshot.                                               |

### Cleaning up a failed host-only network

A failed attempt leaves a dead network entry (for example `VNET_2`, subnet
`192.168.56.0`) in Fusion's network config. It doesn't block the labs, but you
can remove it:

```bash
grep VNET_ "/Library/Preferences/VMware Fusion/networking"   # find the dead one (no DHCP, no bridge)
sudo cp "/Library/Preferences/VMware Fusion/networking" ~/fusion-networking.bak
sudo sed -i '' '/^answer VNET_2_/d' "/Library/Preferences/VMware Fusion/networking"
sudo "/Applications/VMware Fusion.app/Contents/Library/vmnet-cli" --configure
sudo "/Applications/VMware Fusion.app/Contents/Library/vmnet-cli" --stop
sudo "/Applications/VMware Fusion.app/Contents/Library/vmnet-cli" --start
```

Replace `VNET_2` with whichever number is the dead one. **Don't** remove
`VNET_1` (Fusion's host-only network) or `VNET_8` (NAT).

## Uninstalling everything

```bash
vagrant global-status --prune                   # find any lab VMs still around
# in each lab folder:  vagrant destroy -f
vagrant box remove bento/ubuntu-24.04 --all
vagrant plugin uninstall vagrant-vmware-desktop
brew uninstall --cask vagrant-vmware-utility
brew uninstall hashicorp/tap/hashicorp-vagrant  # or: brew uninstall --cask vagrant
rm -rf ~/.vagrant.d                             # Vagrant's boxes, plugins and settings
# VMware Fusion: drag it from /Applications to the Trash
```
