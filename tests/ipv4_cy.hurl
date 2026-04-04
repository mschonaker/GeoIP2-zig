GET http://127.0.0.1:8080/ipv4/94.140.14.14
HTTP/1.1 200
Content-Type: application/json
[Asserts]
jsonpath "$.country.iso_code" == "CY"
jsonpath "$.country.names.en" == "Cyprus"