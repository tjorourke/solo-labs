package main

import (
	"errors"
	"io"
	"log"
	"net"
	"regexp"
	"strconv"

	corev3 "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	extprocv3 "github.com/envoyproxy/go-control-plane/envoy/service/ext_proc/v3"
	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthgrpc "google.golang.org/grpc/health/grpc_health_v1"
)

var credentialPattern = regexp.MustCompile(`(?i)(api[-_]?key|token|bearer|secret|^authorization$|^proxy-authorization$)`)

type processor struct {
	extprocv3.UnimplementedExternalProcessorServer
}

func (processor) Process(stream extprocv3.ExternalProcessor_ProcessServer) error {
	for {
		msg, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}

		out := &extprocv3.ProcessingResponse{}

		switch r := msg.Request.(type) {
		case *extprocv3.ProcessingRequest_RequestHeaders:
			out.Response = &extprocv3.ProcessingResponse_RequestHeaders{
				RequestHeaders: &extprocv3.HeadersResponse{Response: &extprocv3.CommonResponse{}},
			}
		case *extprocv3.ProcessingRequest_RequestBody:
			out.Response = &extprocv3.ProcessingResponse_RequestBody{
				RequestBody: &extprocv3.BodyResponse{Response: &extprocv3.CommonResponse{}},
			}
		case *extprocv3.ProcessingRequest_RequestTrailers:
			out.Response = &extprocv3.ProcessingResponse_RequestTrailers{
				RequestTrailers: &extprocv3.TrailersResponse{},
			}
		case *extprocv3.ProcessingRequest_ResponseHeaders:
			mut := &extprocv3.HeaderMutation{}
			var dropped int
			for _, h := range r.ResponseHeaders.GetHeaders().GetHeaders() {
				name := h.GetKey()
				if name == "" || name[0] == ':' {
					continue
				}
				if credentialPattern.MatchString(name) {
					mut.RemoveHeaders = append(mut.RemoveHeaders, name)
					dropped++
				}
			}
			if dropped > 0 {
				mut.SetHeaders = append(mut.SetHeaders, &corev3.HeaderValueOption{
					Header: &corev3.HeaderValue{
						Key:      "x-redacted-count",
						RawValue: []byte(strconv.Itoa(dropped)),
					},
				})
				log.Printf("response_headers: redacted %d credential-shaped header(s)", dropped)
			}
			out.Response = &extprocv3.ProcessingResponse_ResponseHeaders{
				ResponseHeaders: &extprocv3.HeadersResponse{
					Response: &extprocv3.CommonResponse{HeaderMutation: mut},
				},
			}
		case *extprocv3.ProcessingRequest_ResponseBody:
			out.Response = &extprocv3.ProcessingResponse_ResponseBody{
				ResponseBody: &extprocv3.BodyResponse{Response: &extprocv3.CommonResponse{}},
			}
		case *extprocv3.ProcessingRequest_ResponseTrailers:
			out.Response = &extprocv3.ProcessingResponse_ResponseTrailers{
				ResponseTrailers: &extprocv3.TrailersResponse{},
			}
		}

		if err := stream.Send(out); err != nil {
			return err
		}
	}
}

func main() {
	lis, err := net.Listen("tcp", "0.0.0.0:18080")
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	srv := grpc.NewServer()
	extprocv3.RegisterExternalProcessorServer(srv, processor{})
	healthgrpc.RegisterHealthServer(srv, health.NewServer())
	log.Printf("extproc redactor listening on :18080")
	if err := srv.Serve(lis); err != nil {
		log.Fatalf("serve: %v", err)
	}
}
