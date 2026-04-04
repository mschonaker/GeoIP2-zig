GET http://127.0.0.1:8080/ipv6/2606:4700:4700::1111
HTTP/1.1 200
Content-Type: application/json
[Asserts]
jsonpath "$.registered_country.iso_code" == "US"