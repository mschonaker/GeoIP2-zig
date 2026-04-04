-- mix_ips.lua - wrk script for varied IP lookups
-- Cycles through a list of IP addresses to simulate realistic traffic

local ips = {
    -- US IPs
    "8.8.8.8",      -- Google DNS
    "1.1.1.1",      -- Cloudflare DNS
    "142.250.1.1",  -- Google
    "151.101.1.69", -- Cloudflare CDN
    
    -- International IPs
    "94.140.14.14", -- Cyprus (AdGuard DNS)
    "1.0.1.1",      -- China
    "103.1.200.1",  -- Taiwan
    "8.8.4.4",      -- Google DNS
    
    -- IPv6
    "2001:4860:4860::8888",
    "2606:4700:4700::1111",
    "2001:4860:4860::1",
}

local index = 0

request = function()
    index = (index % #ips) + 1
    local ip = ips[index]
    
    -- Alternate between IPv4 and IPv6
    local path = (index % 2 == 1) and "/ipv4/" or "/ipv6/"
    
    return wrk.format("GET", path .. ip)
end

done = function(summary, latency, requests)
    io.write("--------------------------\n")
    io.write("IP Distribution:\n")
    for i, ip in ipairs(ips) do
        io.write(string.format("  %s\n", ip))
    end
end