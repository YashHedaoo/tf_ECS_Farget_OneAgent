# Fetch OneAgent connection details from the Dynatrace deployment API.
#
# This is the officially documented source for the DT_TENANT / DT_TENANTTOKEN /
# DT_CONNECTION_POINT values the app container needs. Fetching them here means the
# operator still only supplies the API URL + PaaS token — no extra parameters.
#
# Docs: https://docs.dynatrace.com/docs/ingest-from/amazon-web-services/integrate-into-aws/aws-fargate
data "http" "oneagent_connection_info" {
  url = "${var.dynatrace_api_url}/api/v1/deployment/installer/agent/connectioninfo"

  request_headers = {
    Authorization = "Api-Token ${var.dynatrace_paas_token}"
    Accept        = "application/json"
  }
}

locals {
  dt_connection_info = jsondecode(data.http.oneagent_connection_info.response_body)

  dt_tenant       = local.dt_connection_info.tenantUUID
  dt_tenant_token = local.dt_connection_info.tenantToken

  # Semicolon-separated endpoint list expected by DT_CONNECTION_POINT.
  dt_connection_point = try(
    local.dt_connection_info.formattedCommunicationEndpoints,
    join(";", local.dt_connection_info.communicationEndpoints)
  )
}
