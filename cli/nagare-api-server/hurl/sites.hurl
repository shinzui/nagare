# Recorded sites: hostnames from DomainMappings, never live health.
GET {{base_url}}/v1/sites?namespace=personal&first=100
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.edges" count == 12
jsonpath "$.edges[?(@.node.name == 's1')].node.hostnames[0]" == "s1-v1.example.com"
jsonpath "$.edges[?(@.node.name == 's12')].node.state" == "never-converged"

GET {{base_url}}/v1/sites?namespace=elsewhere
HTTP 200
[Asserts]
jsonpath "$.edges" count == 0
