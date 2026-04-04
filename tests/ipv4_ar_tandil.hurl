GET http://127.0.0.1:8080/ipv4/45.5.23.0
HTTP/1.1 200
Content-Type: application/json
[Asserts]
jsonpath "$.country.iso_code" == "AR"
jsonpath "$.country.names.en" == "Argentina"
jsonpath "$.city.names.en" == "Tandil"