# Cloudflare Dashboard Fixes Required for strayaco.com.au SOC 2 P0s
# =================================================================
# These fixes require Cloudflare dashboard access (different account from WeScan)

## P0 #1: Block exposed .git directory
1. Go to Security > WAF > Custom Rules
2. Create rule: "Block .git Access"
   Field: URI Path | Operator: contains | Value: /.git/
   Action: Block
3. Deploy

## P0 #2: Add security headers
1. Go to Rules > Transform Rules > Modify Response Header
2. Create rule: "Security Headers" (all requests)
   Add headers:
   - Strict-Transport-Security: max-age=31536000; includeSubDomains; preload
   - X-Frame-Options: DENY
   - X-Content-Type-Options: nosniff
   - Referrer-Policy: strict-origin-when-cross-origin
   - Content-Security-Policy: default-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data:; script-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none';
3. Deploy

## P0 #3: HTTP → HTTPS redirect
1. Go to SSL/TLS > Edge Certificates
2. Enable "Always Use HTTPS" (toggle ON)
3. Also ensure "Automatic HTTPS Rewrites" is ON
4. Set minimum TLS version to 1.2
