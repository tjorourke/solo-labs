#!/usr/bin/env python3
# guardrail-mcp: an ExtMCP policy server. Implements the ExtMcp gRPC service
# from ext_mcp.proto: agentgateway calls CheckRequest before forwarding an MCP
# call to the backend, and CheckResponse after the backend answers.
#
# Policy, on purpose simple enough to read in one sitting:
#   - tools/call -> delete_contact: deny unless the caller sent X-Role: admin.
#     Every other tools/call: pass unchanged.
#   - tools/list response: mutate it, appending a note to delete_contact's
#     description so a client sees the gate before it ever calls the tool.
#
# agentgateway talks to this over cleartext HTTP/2 (h2c); grpc's insecure
# port already serves that, no TLS setup needed.

import json
import logging
from concurrent import futures

import grpc
from google.protobuf import struct_pb2

import ext_mcp_pb2 as pb
import ext_mcp_pb2_grpc as pb_grpc

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger("guardrail-mcp")

GATED_TOOL = "delete_contact"
REQUIRED_ROLE_HEADER = "x-role"
REQUIRED_ROLE_VALUE = "admin"


def header_value(headers, key):
    key = key.lower()
    for h in headers:
        if h.key.lower() == key:
            return h.value.decode("utf-8", "replace")
    return None


class ExtMcpServicer(pb_grpc.ExtMcpServicer):
    def CheckRequest(self, request, context):
        log.info("CheckRequest method=%s services=%s", request.method, list(request.service_names))

        if request.method != "tools/call" or not request.HasField("mcp_request"):
            return pb.McpRequestResult(**{'pass': pb.Pass()})

        try:
            params = json.loads(request.mcp_request)
        except Exception:
            return pb.McpRequestResult(**{'pass': pb.Pass()})

        tool = params.get("name", "")
        if tool != GATED_TOOL:
            return pb.McpRequestResult(**{'pass': pb.Pass()})

        role = header_value(request.headers, REQUIRED_ROLE_HEADER)
        if role == REQUIRED_ROLE_VALUE:
            log.info("tools/call %s: ALLOW (X-Role: %s)", tool, role)
            return pb.McpRequestResult(**{'pass': pb.Pass()})

        log.info("tools/call %s: DENY (X-Role header was %r, want %r)", tool, role, REQUIRED_ROLE_VALUE)
        return pb.McpRequestResult(
            error=pb.AuthorizationError(
                code=pb.AuthorizationError.PERMISSION_DENIED,
                reason="delete_contact requires an 'X-Role: admin' header",
            )
        )

    def CheckResponse(self, request, context):
        log.info("CheckResponse method=%s services=%s", request.method, list(request.service_names))

        if request.method != "tools/list":
            return pb.McpResponseResult(**{'pass': pb.Pass()})

        try:
            result = json.loads(request.mcp_response)
        except Exception:
            return pb.McpResponseResult(**{'pass': pb.Pass()})

        changed = False
        for tool in result.get("tools", []):
            if tool.get("name") == GATED_TOOL and "[guardrail" not in tool.get("description", ""):
                tool["description"] = tool["description"] + " [guardrail: requires X-Role: admin header]"
                changed = True

        if not changed:
            return pb.McpResponseResult(**{'pass': pb.Pass()})

        log.info("tools/list: MUTATE (annotated %s)", GATED_TOOL)
        return pb.McpResponseResult(mutated=json.dumps(result).encode())


def serve():
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
    pb_grpc.add_ExtMcpServicer_to_server(ExtMcpServicer(), server)
    server.add_insecure_port("[::]:4445")
    log.info("guardrail-mcp (ExtMCP) listening on :4445 (h2c)")
    server.start()
    server.wait_for_termination()


if __name__ == "__main__":
    serve()
