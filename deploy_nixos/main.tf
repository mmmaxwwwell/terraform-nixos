variable "target_host" {
  type        = string
  description = "DNS host to deploy to"
}

variable "target_user" {
  type        = string
  description = "SSH user used to connect to the target_host"
  default     = "root"
}

variable "target_port" {
  type        = number
  description = "SSH port used to connect to the target_host"
  default     = 22
}

variable "ssh_private_key" {
  type        = string
  description = "Content of private key used to connect to the target_host"
  default     = ""
}

variable "ssh_private_key_file" {
  type        = string
  description = "Path to private key used to connect to the target_host"
  default     = ""
}

variable "ssh_agent" {
  type        = bool
  description = "Whether to use an SSH agent. True if not ssh_private_key is passed"
  default     = null
}

variable "NIX_PATH" {
  type        = string
  description = "Allow to pass custom NIX_PATH"
  default     = ""
}

variable "nixos_config" {
  type        = string
  description = "Path to a NixOS configuration"
  default     = ""
}

variable "config" {
  type        = string
  description = "NixOS configuration to be evaluated. This argument is required unless 'nixos_config' is given"
  default     = ""
}

variable "config_pwd" {
  type        = string
  description = "Directory to evaluate the configuration in. This argument is required if 'config' is given"
  default     = ""
}

variable "extra_eval_args" {
  type        = list(string)
  description = "List of arguments to pass to the nix evaluation"
  default     = []
}

variable "extra_build_args" {
  type        = list(string)
  description = "List of arguments to pass to the nix builder"
  default     = []
}

variable "build_on_target" {
  type        = string
  description = "Avoid building on the deployer. Must be true or false. Has no effect when deploying from an incompatible system. Unlike remote builders, this does not require the deploying user to be trusted by its host."
  default     = false
}

variable "triggers" {
  type        = map(string)
  description = "Triggers for deploy"
  default     = {}
}

variable "keys" {
  type        = map(map(string))
  description = "A map of filename to content to upload as secrets in /var/keys"
  default     = {}
}

variable "target_system" {
  type        = string
  description = "Nix system string"
  default     = "x86_64-linux"
}

variable "hermetic" {
  type        = bool
  description = "Treat the provided nixos configuration as a hermetic expression and do not evaluate using the ambient system nixpkgs. Useful if you customize eval-modules or use a pinned nixpkgs."
  default     = false
}

variable "flake" {
  type        = bool
  description = "Treat the provided nixos_config as the NixOS configuration to use in the flake located in the current directory"
  default     = false
}

variable "delete_older_than" {
  type        = string
  description = "Can be a list of generation numbers, the special value old to delete all non-current generations, a value such as 30d to delete all generations older than the specified number of days (except for the generation that was active at that point in time), or a value such as +5 to keep the last 5 generations ignoring any newer than current, e.g., if 30 is the current generation +5 will delete generation 25 and all older generations."
  default     = "+1"
}

variable "install_bootloader" {
  type        = bool
  description = "If the bootloader should be force installed"
  default     = false
}

# --------------------------------------------------------------------------

locals {
  triggers = {
    deploy_nixos_drv  = data.external.nixos-instantiate.result["drv_path"]
    deploy_nixos_keys = sha256(jsonencode(var.keys))
  }

  extra_build_args = concat([
    "--option", "substituters", data.external.nixos-instantiate.result["substituters"],
    "--option", "trusted-public-keys", data.external.nixos-instantiate.result["trusted-public-keys"],
    ],
    var.extra_build_args,
  )
  ssh_private_key_file = var.ssh_private_key_file == "" ? "-" : var.ssh_private_key_file
  ssh_private_key      = local.ssh_private_key_file == "-" ? var.ssh_private_key : file(local.ssh_private_key_file)
  ssh_agent            = var.ssh_agent == null ? (local.ssh_private_key != "") : var.ssh_agent
  build_on_target      = data.external.nixos-instantiate.result["currentSystem"] != var.target_system ? true : tobool(var.build_on_target)
}

# used to detect changes in the configuration
data "external" "nixos-instantiate" {
  program = concat([
    "${path.module}/nixos-instantiate.sh",
    var.NIX_PATH == "" ? "-" : var.NIX_PATH,
    var.config != "" ? var.config : var.nixos_config,
    var.config_pwd == "" ? "." : var.config_pwd,
    var.flake,
    # end of positional arguments
    # start of pass-through arguments
    "--argstr", "system", var.target_system,
    "--arg", "hermetic", var.hermetic
    ],
    var.extra_eval_args,
  )
}

resource "null_resource" "deploy_nixos" {
  triggers = merge(var.triggers, local.triggers)

  connection {
    type        = "ssh"
    host        = var.target_host
    port        = var.target_port
    user        = var.target_user
    agent       = local.ssh_agent
    timeout     = "15s"
    private_key = local.ssh_private_key == "-" ? "" : local.ssh_private_key
  }

  # do the actual deployment
  provisioner "local-exec" {
    interpreter = concat([
      "${path.module}/nixos-deploy.sh",
      data.external.nixos-instantiate.result["drv_path"],
      data.external.nixos-instantiate.result["out_path"],
      "${var.target_user}@${var.target_host}",
      var.target_port,
      local.build_on_target,
      local.ssh_private_key == "" ? "-" : local.ssh_private_key,
      "switch",
      var.delete_older_than,
      jsonencode(var.keys),
      var.config,
      var.config_pwd
      ],
      local.extra_build_args
    )
    command = "ignoreme"
  }

  #copy the configuration.nix onto the remote machine so config.autoUpgrade
  #doesn't destroy our machine state
  # provisioner "remote-exec" {
  #   inline = [
  #     "mkdir -p /etc/nixos",
  #     "mkdir -p /etc/common",
  #     "mkdir -p /etc/common-backup",
  #     "mkdir -p /etc/nixos-backup",
  #     "chmod 600 /etc/nixos-backup",
  #     "chmod 600 /etc/common-backup",
  #     "echo \"$(date +%s)\" > /etc/nixos-backup/DEPLOY_DATE",
  #     "mkdir -p /etc/nixos-backup/$(cat /etc/nixos-backup/DEPLOY_DATE)",
  #     "mkdir -p /etc/common-backup/$(cat /etc/nixos-backup/DEPLOY_DATE)",
  #     "mv /etc/nixos/* /etc/nixos-backup/$(cat /etc/nixos-backup/DEPLOY_DATE)/ || exit 0",
  #     "mv /etc/common/* /etc/common-backup/$(cat /etc/nixos-backup/DEPLOY_DATE)/ || exit 0"
  #   ] 
  # }

  # provisioner "file" {
  #   content = var.config
  #   destination = "/etc/nixos/configuration.nix"
  # }

  # provisioner "file" {
  #   source      = "${var.config_pwd}/../common"
  #   destination = "/etc"
  # }

  #   provisioner "file" {
  #   source      = "${var.config_pwd}/"
  #   destination = "/etc/nixos"
  # }

  # provisioner "remote-exec" {
  #   inline = [
  #     "nixos-rebuild switch --upgrade",
  #   ] 
  # }
}

# --------------------------------------------------------------------------

output "id" {
  description = "random ID that changes on every nixos deployment"
  value       = null_resource.deploy_nixos.id
}

