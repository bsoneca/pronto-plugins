// pronto-api's spike (api/service.ts, PRONTO-289): a descriptor set loaded at run time, with no
// generated stubs, served over native gRPC (h2c), Connect over HTTP/2 and HTTP/1.1, gRPC-Web, and a REST
// route, on one port, only while api_export is on. The descriptor set is given in its JSON
// encoding; the service is handed its binary, as it will read a descriptor set the generator wrote.
package unit

_api: {
	set: file: [{
		name:    "spike/v1/ping.proto"
		package: "spike.v1"
		syntax:  "proto3"
		messageType: [{
			name: "PingRequest"
			field: [
				{name: "text", number: 1, label: "LABEL_OPTIONAL", type: "TYPE_STRING", jsonName: "text"},
				{name: "times", number: 2, label: "LABEL_OPTIONAL", type: "TYPE_INT32", jsonName: "times"},
			]
		}, {
			name: "PingResponse"
			field: [
				{name: "text", number: 1, label: "LABEL_OPTIONAL", type: "TYPE_STRING", jsonName: "text"},
				{name: "count", number: 2, label: "LABEL_OPTIONAL", type: "TYPE_INT32", jsonName: "count"},
			]
		}]
		service: [{name: "PingService", method: [{name: "Ping", inputType: ".spike.v1.PingRequest", outputType: ".spike.v1.PingResponse"}]}]
	}]
	routes: [{method: "GET", path: "/api/v1/ping/{text}", rpc: "spike.v1.PingService/Ping"}]
	pong: {text: "pong:hi", count: 5}
}

cases: {
	"one method of a runtime descriptor set answers the same over gRPC, Connect on HTTP/2 and HTTP/1.1, gRPC-Web, and REST": {suite: "api", steps: [
		{call: "api.called", args: [_api.set, _api.routes, {text: "hi", times: 3}, "/api/v1/ping/hi?times=3"], holds: {
			grpc:      _api.pong
			connectH2: _api.pong
			grpcWeb:   _api.pong
			connectH1: {status: 200, body: _api.pong}
			rest: {status: 200, body: _api.pong}
		}, why: "native gRPC over h2c: the grpc-status trailer reached the client"
		},
	]}
	"with api_export off nothing answers: gRPC and Connect say unimplemented, REST 404": {suite: "api", steps: [
		{call: "api.called", args: [_api.set, _api.routes, {text: "hi", times: 3}, "/api/v1/ping/hi?times=3", false], holds: {
			grpc: {error: 12}
			connectH2: {error: 12}
			grpcWeb: {error: 12}
			connectH1: {status: 501, body: {code: "unimplemented"}}
			rest: {status: 404, body: {code: "not_found"}}
		}},
	]}
	"REST refuses a field it cannot read with 400, and a method that throws is internal everywhere, its message kept back": {suite: "api", steps: [
		{call: "api.called", args: [_api.set, _api.routes, {text: "hi", times: 3}, "/api/v1/ping/hi?times=many"], holds: {
			rest: {status: 400, body: {code: "invalid_argument"}}
		}},
		{call: "api.called", args: [_api.set, _api.routes, {text: "boom"}, "/api/v1/ping/boom"], holds: {
			grpc: {error: 13}
			connectH2: {error: 13}
			grpcWeb: {error: 13}
			connectH1: {status: 500, body: {code: "internal", message: "internal error"}}
			rest: {status: 500, body: {code: "internal", message: "internal error"}}
		}},
	]}
	"the service refuses to start on a service, method or route its descriptor set lacks": {suite: "api", steps: [
		{call: "api.starts", args: [_api.set, _api.routes, {"spike.v1.PingService": ["ping"]}], expect: "started"},
		{call: "api.starts", args: [_api.set, [], {"spike.v1.Nope": ["ping"]}], throws: "no service spike.v1.Nope"},
		{call: "api.starts", args: [_api.set, [], {"spike.v1.PingService": ["pong"]}], throws: "no method pong in spike.v1.PingService"},
		{call: "api.starts", args: [_api.set, [{method: "GET", path: "/api/v1/x", rpc: "spike.v1.PingService/Pong"}], {"spike.v1.PingService": ["ping"]}], throws: "route GET /api/v1/x: no method spike.v1.PingService/Pong"},
	]}
	"a REST route matches its method and every segment, a {field} taking one non-empty segment": {suite: "api", steps: [
		{call: "api.matchRoute", args: [_api.routes, "GET", "/api/v1/ping/a%20b"], holds: {params: {text: "a b"}}},
		{call: "api.matchRoute", args: [_api.routes, "POST", "/api/v1/ping/a"], expect: null},
		{call: "api.matchRoute", args: [_api.routes, "GET", "/api/v1/ping/"], expect: null},
		{call: "api.matchRoute", args: [_api.routes, "GET", "/api/v1/ping/a/b"], expect: null},
	]}
	"api_export is on only when flagd answers true; an error or any other value is off": {suite: "api", steps: [
		{call: "api.flagRead", args: [{status: 200, body: {key: "api_export", value: true}}], expect: true},
		{call: "api.flagRead", args: [{status: 200, body: {key: "api_export", value: false}}], expect: false},
		{call: "api.flagRead", args: [{status: 200, body: {value: "true"}}], expect: false},
		{call: "api.flagRead", args: [{status: 404, body: {errorCode: "FLAG_NOT_FOUND"}}], expect: false, why: "no flag yet is the default: off"},
	]}
}
