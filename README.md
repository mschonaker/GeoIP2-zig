# Unofficial GeoIP2 service written in Zig

## Download the MMDB file

Edit the account id and the license key.

```shell
cat > GeoIP.conf <<EOF
AccountID <YOUR ACCOUNT ID>
LicenseKey <YOUR LICENSE KEY>
EditionIDs GeoLite2-City
EOF
```

```shell
geoipupdate -f GeoIP.conf -d src/
```

## Compile

```shell
zig build --release=fast
```

## Run

```shell
./zig-out/bin/geoip-zig
```

## Test

### IPv4

http://localhost:8080/ipv4/46.17.46.213

### IPv6

http://localhost:8080/ipv6/240e:83:205:2c30:83cf:4b22:83cf:4b23

### Errors

#### Invalid format

http://localhost:8080/ipv4/abcd

http://localhost:8080/ipv6/abcd


#### Unknown target

http://localhost:8080/doesntexist

### Stress test

```shell
siege http://localhost:8080/ipv6/240e:83:205:2c30:83cf:4b22:83cf:4b23
```
