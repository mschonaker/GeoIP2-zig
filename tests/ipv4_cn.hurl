GET http://127.0.0.1:8080/ipv4/1.0.1.1
HTTP/1.1 200
Content-Type: application/json
[Asserts]
jsonpath "$.country.iso_code" == "CN"
jsonpath "$.country.names.en" == "China"