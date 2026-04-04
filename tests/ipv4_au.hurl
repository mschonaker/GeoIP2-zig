GET http://127.0.0.1:8080/ipv4/1.1.1.1
HTTP/1.1 200
Content-Type: application/json
[Asserts]
jsonpath "$.registered_country.iso_code" == "AU"
jsonpath "$.registered_country.names.en" == "Australia"