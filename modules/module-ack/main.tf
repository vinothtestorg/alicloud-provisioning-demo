# Stand-in for the real org module. Kept deliberately thin — the point of the demo is
# the pipeline around it, not this. The one thing it does have to be is valid against
# the pinned provider: worker_instance_types and worker_number were REMOVED in
# alicloud 1.212.0, so node sizing lives in a node pool resource. The variable names
# are unchanged, which keeps the claim schema and the sizing map story intact.
resource "alicloud_cs_managed_kubernetes" "this" {
  name        = var.cluster_name
  vswitch_ids = var.vswitch_ids
  enable_rrsa = var.enable_rrsa
  tags        = var.tags
}

resource "alicloud_cs_kubernetes_node_pool" "workers" {
  cluster_id     = alicloud_cs_managed_kubernetes.this.id
  node_pool_name = "${var.cluster_name}-workers"
  vswitch_ids    = var.vswitch_ids
  instance_types = [var.worker_instance_type]
  desired_size   = var.worker_count
}

resource "alicloud_cs_kubernetes_permissions" "ns" {
  count = length(var.namespaces)
  # placeholder for namespace creation in the demo module
  uid   = "placeholder"
}
