GET http://127.0.0.1:8080/ipv4/8.8.8.8?f=!registered_country,!continent.names
HTTP/1.1 200
Content-Type: application/json
[Asserts]
jsonpath "$.registered_country" not exists
jsonpath "$.continent.code" == "NA"
jsonpath "$.continent.names" not exists
jsonpath "$.country.names.en" == "United States"
jsonpath "$.location.time_zone" == "America/Chicago"
