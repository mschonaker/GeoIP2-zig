GET http://127.0.0.1:8080/ipv6/2001:4860:4860::8888
HTTP/1.1 200
Content-Type: application/json
[Asserts]
jsonpath "$.country.iso_code" == "US"
jsonpath "$.country.names.en" == "United States"