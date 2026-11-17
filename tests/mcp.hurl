POST http://127.0.0.1:8080/mcp
Content-Type: application/json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2024-11-05",
    "capabilities": {},
    "clientInfo": { "name": "hurl", "version": "1" }
  }
}

HTTP 200
[Asserts]
jsonpath "$.jsonrpc" == "2.0"
jsonpath "$.id" == 1
jsonpath "$.result.protocolVersion" == "2024-11-05"
jsonpath "$.result.serverInfo.name" == "geoip-zig"

POST http://127.0.0.1:8080/mcp
Content-Type: application/json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/list"
}

HTTP 200
[Asserts]
jsonpath "$.result.tools[0].name" == "lookup_ipv4"
jsonpath "$.result.tools[1].name" == "lookup_ipv6"
jsonpath "$.result.tools[0].inputSchema.required[0]" == "ip"

POST http://127.0.0.1:8080/mcp
Content-Type: application/json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": { "name": "lookup_ipv4", "arguments": { "ip": "8.8.8.8" } }
}

HTTP 200
[Asserts]
jsonpath "$.result.content[0].type" == "text"
jsonpath "$.result.content[0].text" contains "\"iso_code\":\"US\""
jsonpath "$.result.content[0].text" contains "\"code\":\"NA\""

POST http://127.0.0.1:8080/mcp
Content-Type: application/json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "tools/call",
  "params": { "name": "lookup_ipv6", "arguments": { "ip": "2001:4860:4860::8888" } }
}

HTTP 200
[Asserts]
jsonpath "$.result.content[0].type" == "text"
jsonpath "$.result.content[0].text" contains "\"iso_code\":\"US\""

POST http://127.0.0.1:8080/mcp
Content-Type: application/json
{
  "jsonrpc": "2.0",
  "id": 5,
  "method": "tools/call",
  "params": { "name": "lookup_ipv4", "arguments": { "ip": "127.0.0.1" } }
}

HTTP 200
[Asserts]
jsonpath "$.result.isError" == true
jsonpath "$.result.content[0].text" == "IP not found in database"

POST http://127.0.0.1:8080/mcp
Content-Type: application/json
{
  "jsonrpc": "2.0",
  "id": 6,
  "method": "tools/call",
  "params": { "name": "lookup_ipv6", "arguments": { "ip": "8.8.8.8" } }
}

HTTP 200
[Asserts]
jsonpath "$.result.isError" == true
jsonpath "$.result.content[0].text" == "Invalid IP format"

POST http://127.0.0.1:8080/mcp
Content-Type: application/json
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "unknown/method"
}

HTTP 200
[Asserts]
jsonpath "$.error.code" == -32601

POST http://127.0.0.1:8080/mcp
Content-Type: application/json
{ "jsonrpc": "1.0", "id": 8, "method": "initialize" }

HTTP 400
[Asserts]
jsonpath "$.error.code" == -32600

GET http://127.0.0.1:8080/mcp

HTTP 405
