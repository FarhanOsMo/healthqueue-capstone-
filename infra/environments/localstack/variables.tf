variable "localstack_endpoint" {
  description = "LocalStack edge endpoint. Must be a local URL."
  type        = string
  default     = "http://localhost:4566"

  validation {
    condition     = can(regex("^http://(localhost|127[.]0[.]0[.]1|localstack)(:[0-9]+)?$", var.localstack_endpoint))
    error_message = "The localstack_endpoint value must point at a local LocalStack instance."
  }
}
