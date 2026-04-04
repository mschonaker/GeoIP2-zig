GET http://127.0.0.1:8080/ipv4/8.8.8.8
HTTP/1.1 200
Content-Type: application/json
[Asserts]
jsonpath "$.country.iso_code" == "US"
jsonpath "$.country.names.en" == "United States"
jsonpath "$.continent.code" == "NA"