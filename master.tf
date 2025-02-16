module "first_control_plane" {
  source = "./modules/host"

  name = "k3s-control-plane-0"

  ssh_keys               = [hcloud_ssh_key.k3s.id]
  public_key             = var.public_key
  private_key            = var.private_key
  additional_public_keys = var.additional_public_keys
  firewall_ids           = [hcloud_firewall.k3s.id]
  placement_group_id     = hcloud_placement_group.k3s.id
  location               = var.location
  network_id             = hcloud_network.k3s.id
  ip                     = local.first_control_plane_network_ip
  server_type            = var.control_plane_server_type

  labels = {
    "provisioner" = "terraform",
    "engine"      = "k3s"
  }

  hcloud_token = var.hcloud_token
}

resource "null_resource" "first_control_plane" {

  triggers = {
    first_control_plane_id = module.first_control_plane.id
  }


  connection {
    user           = "root"
    private_key    = local.ssh_private_key
    agent_identity = local.ssh_identity
    host           = module.first_control_plane.ipv4_address
  }

  # Generating k3s master config file
  provisioner "file" {
    content = yamlencode({
      node-name                = module.first_control_plane.name
      token                    = random_password.k3s_token.result
      cluster-init             = true
      disable-cloud-controller = true
      disable                  = ["servicelb", "local-storage"]
      flannel-iface            = "eth1"
      kubelet-arg              = "cloud-provider=external"
      node-ip                  = local.first_control_plane_network_ip
      advertise-address        = local.first_control_plane_network_ip
      tls-san                  = local.first_control_plane_network_ip
      node-taint               = var.allow_scheduling_on_control_plane ? [] : ["node-role.kubernetes.io/master:NoSchedule"]
      node-label               = var.automatically_upgrade_k3s ? ["k3s_upgrade=true"] : []
    })
    destination = "/tmp/config.yaml"
  }

  # Install k3s server
  provisioner "remote-exec" {
    inline = local.install_k3s_server
  }

  # Upon reboot verify that the k3s server is starts, and wait for k3s to be ready to receive commands
  provisioner "remote-exec" {
    inline = [
      "systemctl start k3s",
      # prepare the post_install directory
      "mkdir -p /tmp/post_install",
      # wait for k3s to become ready
      <<-EOT
      timeout 120 bash <<EOF
        until systemctl status k3s > /dev/null; do
          systemctl start k3s
          echo "Waiting for the k3s server to start..."
          sleep 2
        done
        until [ -e /etc/rancher/k3s/k3s.yaml ]; do
          echo "Waiting for kubectl config..."
          sleep 2
        done
        until [[ "\$(kubectl get --raw='/readyz' 2> /dev/null)" == "ok" ]]; do
          echo "Waiting for the cluster to become ready..."
          sleep 2
        done
      EOF
      EOT
    ]
  }

  # Upload kustomization.yaml, containing Hetzner CSI & CSM, as well as kured.
  provisioner "file" {
    content = yamlencode({
      apiVersion = "kustomize.config.k8s.io/v1beta1"
      kind       = "Kustomization"
      resources = [
        "https://github.com/hetznercloud/hcloud-cloud-controller-manager/releases/download/${local.ccm_version}/ccm-networks.yaml",
        "https://raw.githubusercontent.com/hetznercloud/csi-driver/${local.csi_version}/deploy/kubernetes/hcloud-csi.yml",
        "https://github.com/weaveworks/kured/releases/download/${local.kured_version}/kured-${local.kured_version}-dockerhub.yaml",
        "https://raw.githubusercontent.com/rancher/system-upgrade-controller/master/manifests/system-upgrade-controller.yaml",
        "traefik.yaml",
      ]
      patchesStrategicMerge = [
        file("${path.module}/kustomize/kured.yaml"),
        file("${path.module}/kustomize/ccm.yaml"),
        file("${path.module}/kustomize/system-upgrade-controller.yaml")
      ]
    })
    destination = "/tmp/post_install/kustomization.yaml"
  }

  # Upload traefik config
  provisioner "file" {
    content = templatefile(
      "${path.module}/templates/traefik_config.yaml.tpl",
      {
        lb_disable_ipv6    = var.lb_disable_ipv6
        lb_server_type     = var.lb_server_type
        location           = var.location
        traefik_acme_tls   = var.traefik_acme_tls
        traefik_acme_email = var.traefik_acme_email
    })
    destination = "/tmp/post_install/traefik.yaml"
  }

  # Upload the system upgrade controller plans config
  provisioner "file" {
    content = templatefile(
      "${path.module}/templates/plans.yaml.tpl",
      {
        channel = var.k3s_upgrade_channel
    })
    destination = "/tmp/post_install/plans.yaml"
  }

  # Deploy secrets, logging is automatically disabled due to sensitive variables
  provisioner "remote-exec" {
    inline = [
      "set -ex",
      "kubectl -n kube-system create secret generic hcloud --from-literal=token=${var.hcloud_token} --from-literal=network=${hcloud_network.k3s.name}",
      "kubectl -n kube-system create secret generic hcloud-csi --from-literal=token=${var.hcloud_token}",
    ]
  }

  # Deploy our post-installation kustomization
  provisioner "remote-exec" {
    inline = [
      "set -ex",
      # This ugly hack is here, because terraform serializes the
      # embedded yaml files with "- |2", when there is more than
      # one yamldocument in the embedded file. Kustomize does not understand
      # that syntax and tries to parse the blocks content as a file, resulting
      # in weird errors. so gnu sed with funny escaping is used to
      # replace lines like "- |3" by "- |" (yaml block syntax).
      # due to indendation this should not changes the embedded
      # manifests themselves
      "sed -i 's/^- |[0-9]\\+$/- |/g' /tmp/post_install/kustomization.yaml",
      "kubectl apply -k /tmp/post_install",
      "echo 'Waiting for the system-upgrade-controller deployment to become available...'",
      "kubectl -n system-upgrade wait --for=condition=available --timeout=120s deployment/system-upgrade-controller",
      "kubectl -n system-upgrade apply -f /tmp/post_install/plans.yaml"
    ]
  }

  depends_on = [
    hcloud_network_subnet.k3s,
    hcloud_firewall.k3s
  ]
}
