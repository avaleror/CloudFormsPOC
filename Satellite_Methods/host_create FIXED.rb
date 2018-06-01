#
# Description: Create configured host record in Foreman, with 2nd adapter
#

@method = 'register_foreman'

$evm.log("info", "#{@method} - EVM Automate Method Started")

# Dump all of root's attributes to the log
$evm.root.attributes.sort.each { |k, v| $evm.log("info", "#{@method} Root:<$evm.root> Attribute - #{k}: #{v}")}

require 'rest-client'
require 'json'
require 'openssl'
require 'base64'

foreman_host     = $evm.object['satellite_host']
foreman_user     = $evm.object['satellite_user']
foreman_password = $evm.object.decrypt('satellite_password')

hostgroup_id = nil

# Grab the VM object
$evm.log(:info, "vmdb_object_type => <#{$evm.root['vmdb_object_type']}>")
case $evm.root['vmdb_object_type']
when 'miq_provision'
  prov = $evm.root['miq_provision']
  vm   = prov.vm unless prov.nil?

  ip_address      = prov.options[:dialog_ip_address]
  hostgroup_id 		= prov.options[:dialog_host_group]
  location_id 		= prov.options[:dialog_location]
  organization_id = 1
else
  vm = $evm.root['vm']

  ip_address      = $evm.root['dialog_ip_address']
  hostgroup_id 		= $evm.root['dialog_host_group']
  location_id 		= $evm.root['dialog_location']
  organization_id = 1
end
$evm.log(:warn, 'VM object is empty') if vm.nil?

# Only continue if we have the necessary vars
exit MIQ_OK if hostgroup_id.nil?

$evm.log("info", "vm.mac_addresses: #{vm.mac_addresses.inspect}")

@uri_base = "https://#{foreman_host}/api/v2"
@headers = {
  :content_type  => 'application/json',
  :accept        => 'application/json;version=2',
  :authorization => "Basic #{Base64.strict_encode64("#{foreman_user}:#{foreman_password}")}"
}

def query_id (queryuri, queryfield, querycontent)
  # queryuri: path name related to @uri_base, where to search (hostgroups, locations, ...)
  # queryfield: which field (as in database row) should be searched
  # querycontent: what the queryfield has to match (exact match)

  # Put the search URL together
  url = URI.escape("#{@uri_base}/#{queryuri}?search=#{queryfield}=\"#{querycontent}\"")
  
  $evm.log("info", "url => #{url}")

  request = RestClient::Request.new(
    method: :get,
    url: url,
    headers: @headers,
    verify_ssl: OpenSSL::SSL::VERIFY_NONE
  )

  rest_result = request.execute
  json_parse = JSON.parse(rest_result)
  
  # The subtotal value is the number of matching results.
  # If it is higher than one, the query got no unique result!
  subtotal = json_parse['subtotal'].to_i
  
  if subtotal == 0
    $evm.log("info", "query failed, no result #{url}")
    return -1
  elsif subtotal == 1
    id = json_parse['results'][0]['id'].to_s
    return id
  elsif subtotal > 1
    $evm.log("info", "query failed, more than one result #{url}")
    return -1
  end

  $evm.log("info", "query failed, unknown condition #{url}")
  return -1
end

$evm.log("info", "hostgroup_id:    #{hostgroup_id}")
$evm.log("info", "location_id:     #{location_id}")
$evm.log("info", "organization_id: #{organization_id}")

# Create the host via Foreman
uri = "#{@uri_base}"
$evm.log("info", 'Creating host in Foreman')

hostinfo = {
  :name	            => vm.name,
  :mac              => vm.mac_addresses.first,
  :hostgroup_id     => hostgroup_id,
  :location_id      => location_id,
  :organization_id  => organization_id,
  :build            => 'true',
  :ip               => ip_address,
  :subnet_id        => query_id("subnets", "name", 'VLAN244')
}
$evm.log("info", "Sending Host Details: #{hostinfo}")

uri = "#{@uri_base}/hosts"
$evm.log(:info, uri)
request = RestClient::Request.new(
  method:     :post,
  url:        uri,
  headers:    @headers,
  verify_ssl: OpenSSL::SSL::VERIFY_NONE,
  payload:    { host: hostinfo }.to_json
)

rest_result = request.execute
$evm.log("info", "return code => <#{rest_result.code}>")

json_parse = JSON.parse(rest_result)
hostid = json_parse['id'].to_s

$evm.log("info", "Storing Foreman host ID of new VM: #{hostid}")
prov.set_option(:hostid, hostid) unless prov.nil?

# Start
sleep 10
$evm.log("info", "Starting VM")
#vm.stop
vm.start
