#use this for SQS https://gist.github.com/afloesch/dc7d8865eeb91100648330a46967be25

resource "aws_api_gateway_rest_api" "this" {
  name              = var.api_name
  description       = var.description
  put_rest_api_mode = var.put_rest_api_mode
  body              = var.openapi_definition

  endpoint_configuration {
    types = [ var.endpoint_type ]
  }
}

resource "aws_api_gateway_model" "this" {
  for_each = var.models
  rest_api_id  = aws_api_gateway_rest_api.this.id
  name         = each.key
  description  = lookup(each.value,"description","")
  content_type = lookup(each.value,"content_type","")
  schema = lookup(each.value,"schema",{})
}

resource "aws_api_gateway_deployment" "this" {
  for_each = toset(var.stage_names)

  rest_api_id = aws_api_gateway_rest_api.this.id
  description = lookup(var.deployment_version,each.key)
  triggers = {
    # NOTE: The configuration below will satisfy ordering considerations,
    #       but not pick up all future REST API changes. More advanced patterns
    #       are possible, such as using the filesha1() function against the
    #       Terraform configuration file(s) or removing the .id references to
    #       calculate a hash against whole resources. Be aware that using whole
    #       resources will show a difference after the initial implementation.
    #       It will stabilize to only change when resources change afterwards.

    #       We can use this method if we want to isolate deploys to a specific
    #       resource or resource attribute. But for now we just deploy every time
    #       with {timestamp()}.
    #       https://github.com/hashicorp/terraform-provider-aws/issues/162

    # redeployment = sha1(jsonencode([
    #   aws_api_gateway_rest_api.this.body
    #   ]
    # ))

    # We deploy the API every time Terraform is applied instead of using the
    # above method of only applying when the body of the openapi.yaml is
    # updated.
    # redeployment = "${timestamp()}"
    redeployment = sha1(jsonencode([
      lookup(var.deployment_version,each.key)
    ]))
  }

  depends_on = [
    aws_api_gateway_integration.this
  ]
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "this" {
  for_each = toset(var.stage_names)

  rest_api_id           = aws_api_gateway_rest_api.this.id
  stage_name            = each.key
  description           = ""
  documentation_version = var.documentation_version
  deployment_id         = aws_api_gateway_deployment.this[each.key].id
  cache_cluster_enabled = var.cache_cluster_enabled
  cache_cluster_size    = var.cache_cluster_size
  client_certificate_id = var.client_certificate_id
  variables             = var.stage_variables
  xray_tracing_enabled  = var.xray_tracing_enabled

  # dynamic "access_log_settings" {
  #   for_each = aws_cloudwatch_log_group.this.arn != null && var.access_log_format != null ? [true] : []

  #   content {
  #     destination_arn = aws_cloudwatch_log_group.this.arn
  #     format          = var.access_log_format
  #   }
  # }
  # dynamic "canary_settings" {
  #   for_each = var.enable_canary == true ? [true] : []

  #   content {
  #     percent_traffic          = var.percent_traffic
  #     stage_variable_overrides = var.stage_variable_overrides
  #     use_stage_cache          = var.use_stage_cache
  #   }
  # }
  lifecycle {
    create_before_destroy = false
  }
}

resource "aws_api_gateway_resource" "this" {
  for_each = { for k,v in var.resources: k => v if element(split(" ", k),0) != "/"}
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = trimprefix(element(split(" ", each.key),0),"/")
}

resource "aws_api_gateway_method" "this" {
  for_each = var.resources
  rest_api_id          = aws_api_gateway_rest_api.this.id
  resource_id          = element(split(" ", each.key),0) == "/" ? data.aws_api_gateway_resource.root.id : aws_api_gateway_resource.this[each.key].id
  api_key_required     = lookup(each.value, "api_key_required")
  http_method          = element(split(" ", each.key),1)
  authorization        = lookup(each.value, "authorization")
  request_validator_id = lookup(each.value, "request_validator_id",null)
  request_parameters   = lookup(each.value, "request_parameters", null)
  request_models        = lookup(each.value, "request_models", null)

  depends_on = [aws_api_gateway_model.this]
}

resource "aws_api_gateway_method_settings" "this" {
  for_each = var.method_settings

  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = element(split(" ", each.key), 0)
  method_path = element(split(" ", each.key), 1)

  dynamic "settings" {
    for_each = length(var.method_settings) > 0 ? [true] : []
    content {
      metrics_enabled                            = lookup(each.value, "metrics_enabled",false)
      logging_level                              = lookup(each.value, "logging_level","OFF")
      # data_trace_enabled                         = settings.data_trace_enabled
      # throttling_burst_limit                     = settings.throttling_burst_limit
      # throttling_rate_limit                      = settings.throttling_rate_limit
      # caching_enabled                            = settings.caching_enabled
      # cache_ttl_in_seconds                       = settings.cache_ttl_in_seconds
      # cache_data_encrypted                       = settings.cache_data_encrypted
      # require_authorization_for_cache_control    = settings.require_authorization_for_cache_control
      # unauthorized_cache_control_header_strategy = settings.unauthorized_cache_control_header_strategy
    }
  }
  depends_on = [aws_api_gateway_account.this]
}

resource "aws_api_gateway_method_response" "this" {
  for_each = var.resources
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = element(split(" ", each.key),0) == "/" ? data.aws_api_gateway_resource.root.id : aws_api_gateway_resource.this[each.key].id
  http_method = aws_api_gateway_method.this[each.key].http_method
  status_code = lookup(each.value,"status_code",null)

  response_models = lookup(each.value,"response_models",null)
}

resource "aws_api_gateway_integration" "this" {
  for_each = var.integrations
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = element(split(" ", each.key),0) == "/" ? data.aws_api_gateway_resource.root.id : aws_api_gateway_resource.this[each.key].id
  http_method             = aws_api_gateway_method.this[each.key].http_method
  type                    = lookup(each.value, "type", null)
  integration_http_method = lookup(each.value, "integration_http_method", null)
  passthrough_behavior    = lookup(each.value, "passthrough_behavior", null)
  credentials             = lookup(each.value, "credentials", null)
  uri                     = lookup(each.value, "uri", null)

  request_parameters = lookup(each.value, "request_parameters", null)
  request_templates = lookup(each.value, "request_templates", null)
}

resource "aws_api_gateway_integration_response" "this" {
  for_each = var.integrations
  rest_api_id       = aws_api_gateway_rest_api.this.id
  resource_id       = element(split(" ", each.key),0) == "/" ? data.aws_api_gateway_resource.root.id : aws_api_gateway_resource.this[each.key].id
  http_method       = aws_api_gateway_integration.this[each.key].http_method
  status_code       = lookup(each.value,"status_code",null)

  response_templates = lookup(each.value,"response_templates",null)
}

resource "aws_api_gateway_account" "this" {
  cloudwatch_role_arn = var.cloudwatch_role_arn
}
resource "aws_api_gateway_api_key" "this" {
  for_each = {
    for key in var.api_keys : key.name => {
      name = key.name
    }
    if var.create_usage_plan == true && var.enable_api_key == true && length(var.stage_names) > 0
  }
  enabled = var.enable_api_key
  name    = each.value.name
}

resource "aws_api_gateway_usage_plan" "this" {
  for_each = {
    for key in var.usage_plans : key.name => {
      name         = key.name
      description  = key.description
      burst_limit  = key.burst_limit
      rate_limit   = key.rate_limit
      quota_limit  = key.quota_limit
      quota_offset = key.quota_offset
      quota_period = key.quota_period
      stages       = key.stages
    }
    if var.create_usage_plan == true && length(var.stage_names) > 0
  }

  name        = var.client_name == null ? "${each.value.name}" : "${each.value.name}"
  description = var.client_name == null ? "${each.value.description}" : "${each.value.description} for ${var.client_name}."
  dynamic "api_stages" {
    for_each = each.value.stages
    content {
      api_id = aws_api_gateway_rest_api.this.id
      stage  = api_stages.value
    }
  }
  quota_settings {
    limit  = each.value.quota_limit
    offset = each.value.quota_offset
    period = each.value.quota_period
  }
  throttle_settings {
    burst_limit = each.value.burst_limit
    rate_limit  = each.value.rate_limit
  }
  depends_on = [
    aws_api_gateway_stage.this
  ]
}

resource "aws_api_gateway_usage_plan_key" "this" {
  for_each = {
    for key in var.api_keys : key.name => {
      name       = key.name
      key_type   = key.key_type
      usage_plan = key.usage_plan
    }
    if var.create_usage_plan == true && length(var.stage_names) > 0
  }

  key_id        = aws_api_gateway_api_key.this[each.key].id
  key_type      = each.value.key_type
  usage_plan_id = aws_api_gateway_usage_plan.this[each.value.usage_plan].id
  depends_on = [
    aws_api_gateway_api_key.this,
    aws_api_gateway_usage_plan.this,
  ]
}

resource "aws_cloudwatch_log_group" "this" {
  for_each = toset(var.stage_names)
  name              = "${var.log_group_name}/${each.key}"
  retention_in_days = var.log_group_retention_in_days
  kms_key_id        = var.log_group_kms_key
}

resource "aws_wafv2_web_acl_association" "this" {
  for_each        = var.enable_waf != false ? toset(var.stage_names) : []
  resource_arn = aws_api_gateway_stage.this[each.key].arn
  web_acl_arn  = var.waf_acl
}

# REGIONAL custom domain name
resource "aws_api_gateway_domain_name" "regional_acm" {
  for_each = var.create_api_domain_name && var.endpoint_type == "REGIONAL" && var.certificate_type == "ACM" ? toset(var.stage_names) : []

  domain_name = var.domain_names[each.key]

  regional_certificate_arn = var.domain_certificate_arn

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  dynamic "mutual_tls_authentication" {
    for_each = length(keys(var.mutual_tls_authentication)) == 0 ? [] : [var.mutual_tls_authentication]

    content {
      truststore_uri     = mutual_tls_authentication.value.truststore_uri
      truststore_version = try(mutual_tls_authentication.value.truststore_version, null)
    }
  }
}

resource "aws_api_gateway_base_path_mapping" "regional_acm" {
  for_each = var.create_api_domain_name && var.endpoint_type == "REGIONAL" && var.certificate_type == "ACM" ? toset(var.stage_names) : []

  api_id      = aws_api_gateway_rest_api.this.id
  domain_name = aws_api_gateway_domain_name.regional_acm[each.key].id
  stage_name  = aws_api_gateway_stage.this[each.key].stage_name
}

resource "aws_api_gateway_domain_name" "regional_iam" {
  for_each = var.create_api_domain_name && var.endpoint_type == "REGIONAL" && var.certificate_type == "IAM" ? toset(var.stage_names) : []

  domain_name = var.domain_names[each.key]

  regional_certificate_name = var.domain_certificate_name
  certificate_body          = var.iam_certificate_body
  certificate_chain         = var.iam_certificate_chain
  certificate_private_key   = var.iam_certificate_private_key

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  dynamic "mutual_tls_authentication" {
    for_each = length(keys(var.mutual_tls_authentication)) == 0 ? [] : [var.mutual_tls_authentication]

    content {
      truststore_uri     = mutual_tls_authentication.value.truststore_uri
      truststore_version = try(mutual_tls_authentication.value.truststore_version, null)
    }
  }
}

resource "aws_api_gateway_base_path_mapping" "regional_iam" {
  for_each = var.create_api_domain_name && var.endpoint_type == "REGIONAL" && var.certificate_type == "IAM" ? toset(var.stage_names) : []

  api_id      = aws_api_gateway_rest_api.this.id
  domain_name = aws_api_gateway_domain_name.regional_iam[each.key].id
  stage_name  = aws_api_gateway_stage.this[each.key].stage_name
}


resource "aws_api_gateway_domain_name" "edge_acm" {
  for_each = var.create_api_domain_name && var.endpoint_type == "EDGE" && var.certificate_type == "ACM" ? toset(var.stage_names) : []

  domain_name = var.domain_names[each.key]

  certificate_arn = var.domain_certificate_arn

  endpoint_configuration {
    types = ["EDGE"]
  }

  dynamic "mutual_tls_authentication" {
    for_each = length(keys(var.mutual_tls_authentication)) == 0 ? [] : [var.mutual_tls_authentication]

    content {
      truststore_uri     = mutual_tls_authentication.value.truststore_uri
      truststore_version = try(mutual_tls_authentication.value.truststore_version, null)
    }
  }
}

resource "aws_api_gateway_base_path_mapping" "edge_acm" {
  for_each = var.create_api_domain_name && var.endpoint_type == "EDGE" && var.certificate_type == "ACM" ? toset(var.stage_names) : []

  api_id      = aws_api_gateway_rest_api.this.id
  domain_name = aws_api_gateway_domain_name.edge_acm[each.key].id
  stage_name  = aws_api_gateway_stage.this[each.key].stage_name
}

# EDGE custom domain name
resource "aws_api_gateway_domain_name" "edge_iam" {
  for_each = var.create_api_domain_name && var.endpoint_type == "EDGE" && var.certificate_type == "IAM" ? toset(var.stage_names) : []

  domain_name = var.domain_names[each.key]

  certificate_name          = var.domain_certificate_name
  certificate_body          = var.iam_certificate_body
  certificate_chain         = var.iam_certificate_chain
  certificate_private_key   = var.iam_certificate_private_key

  endpoint_configuration {
    types = ["EDGE"]
  }

  dynamic "mutual_tls_authentication" {
    for_each = length(keys(var.mutual_tls_authentication)) == 0 ? [] : [var.mutual_tls_authentication]

    content {
      truststore_uri     = mutual_tls_authentication.value.truststore_uri
      truststore_version = try(mutual_tls_authentication.value.truststore_version, null)
    }
  }
}

resource "aws_api_gateway_base_path_mapping" "edge_iam" {
  for_each = var.create_api_domain_name && var.endpoint_type == "EDGE" && var.certificate_type == "IAM" ? toset(var.stage_names) : []

  api_id      = aws_api_gateway_rest_api.this.id
  domain_name = aws_api_gateway_domain_name.edge_iam[each.key].id
  stage_name  = aws_api_gateway_stage.this[each.key].stage_name
}

resource "aws_api_gateway_rest_api_policy" "this" {
  for_each = var.create_rest_api_policy ? toset(var.stage_names) : []

  rest_api_id = aws_api_gateway_rest_api.this.id
  policy      = var.rest_api_policy
}
