backend F_origin {
    .connect_timeout = 5s;
    .dynamic = true;
    .port = "443";
    .host = "foo";
    .first_byte_timeout = 15s;
    .max_connections = 200;
    .between_bytes_timeout = 10s;
    .share_key = "123";

    .ssl = true;
    .ssl_check_cert = always;
    .min_tls_version = "1.2";
    .ssl_cert_hostname = "foo";
    .ssl_sni_hostname = "foo";

    .probe = {
        .request =
            "HEAD / HTTP/1.1"
            "Host: foo"
            "User-Agent: Fastly healthcheck (git version: )"

            "Connection: close";
        .threshold = 1;
        .window = 2;
        .timeout = 5s;
        .initial = 1;
        .expected_response = 200;
        .interval = 10s;
    }
}
backend sick_force_grace {
  .host = "127.0.0.1";
  .port = "1";
  .probe = {
    .request = "invalid";
    .interval = 365d;
    .initial = 0;
  }
}


acl purge_ip_allowlist {
  "37.26.93.252";     # Skyscape mirrors
  "31.210.241.100";   # Carrenza mirrors
  "23.235.32.0"/20;   # Fastly cache node
  "43.249.72.0"/22;   # Fastly cache node
  "103.244.50.0"/24;  # Fastly cache node
  "103.245.222.0"/23; # Fastly cache node
  "103.245.224.0"/24; # Fastly cache node
  "104.156.80.0"/20;  # Fastly cache node
  "151.101.0.0"/16;   # Fastly cache node
  "157.52.64.0"/18;   # Fastly cache node
  "172.111.64.0"/18;  # Fastly cache node
  "185.31.16.0"/22;   # Fastly cache node
  "199.27.72.0"/21;   # Fastly cache node
  "199.232.0.0"/16;   # Fastly cache node
  "202.21.128.0"/24;  # Fastly cache node
  "203.57.145.0"/24;  # Fastly cache node
  "167.82.0.0"/17;    # Fastly cache node
  "167.82.128.0"/20;  # Fastly cache node
  "167.82.160.0"/20;  # Fastly cache node
  "167.82.224.0"/20;  # Fastly cache node
}

sub vcl_recv {

  # Require authentication for FASTLYPURGE requests unless from IP in ACL
  if (req.request == "FASTLYPURGE" && client.ip !~ purge_ip_allowlist) {
    set req.http.Fastly-Purge-Requires-Auth = "1";
  }

  # Force SSL.
  if (!req.http.Fastly-SSL) {
     error 801 "Force SSL";
  }

  # Serve from stale for 24 hours if origin is sick
  set req.grace = 24h;

  # Default backend.
  set req.backend = F_origin;

  # Serve stale if it exists.
  if (req.restarts > 0) {
    set req.backend = sick_force_grace;
  }

  # Serve from stale for 24 hours if origin is sick
  set req.grace = 24h;

  # Unspoofable original client address
  set req.http.True-Client-IP = req.http.Fastly-Client-IP;

  # Route request to application depending on HTTP method used
  if (req.request ~ "^(PATCH|PUT|POST|DELETE)$") {
    set req.http.Host = "backdrop-write.boo";
  } else if (req.request ~ "^(GET|HEAD|OPTIONS)$") {
    set req.http.Host = "backdrop-read.boo";
  } else {
    error 405 "Method not allowed";
  }

  if (req.url ~ "^/big-screen.*$") {
    set req.http.x-redir = "https://www.gov.uk/performance" req.url;
    error 750 "Moved Permanently";
  }

  # Unspoofable client IP address
  set req.http.True-Client-IP = req.http.Fastly-Client-IP;

  # govuk request id. Allow setting this so we can trace a full request
  if (!req.http.GOVUK-Request-Id) {
    set req.http.GOVUK-Request-Id = server.identity "-" req.xid;
  }

#FASTLY recv

  if (req.request != "HEAD" && req.request != "GET" && req.request != "FASTLYPURGE") {
    return(pass);
  }

  return(lookup);
}

sub vcl_fetch {
#FASTLY fetch

  if ((beresp.status >= 500 && beresp.status <= 599) && req.restarts < 3 && (req.request == "GET" || req.request == "HEAD") && !beresp.http.No-Fallback) {
    set beresp.saintmode = 5s;
    return (restart);
  }

  if (req.restarts == 0) {
    # Keep stale for origin
    set beresp.grace = 24h;
  }

  if(req.restarts > 0 ) {
    set beresp.http.Fastly-Restarts = req.restarts;
  }

  if (beresp.http.Cache-Control ~ "private") {
    set req.http.Fastly-Cachetype = "PRIVATE";
    return (pass);
  }

  if (beresp.http.Cache-Control ~ "max-age=0") {
    return (pass);
  }

  if (beresp.http.Cache-Control ~ "no-(store|cache)") {
    return (pass);
  }

  if (beresp.status >= 500 && beresp.status <= 599) {
    set req.http.Fastly-Cachetype = "ERROR";
    set beresp.ttl = 1s;
    set beresp.grace = 5s;
    return (deliver);
  }

  if (beresp.http.Expires || beresp.http.Surrogate-Control ~ "max-age" || beresp.http.Cache-Control ~"(s-maxage|max-age)") {
    # keep the ttl here
  } else {
    # apply the default ttl
    set beresp.ttl = 5000s;
  }

  # Override default.vcl behaviour of return(pass).
  if (beresp.http.Set-Cookie) {
    return (deliver);
  }
}

sub vcl_hit {
#FASTLY hit
}

sub vcl_miss {
#FASTLY miss
}

sub vcl_deliver {
#FASTLY deliver
}

sub vcl_error {
  if (obj.status == 801) {
    set obj.status = 301;
    set obj.response = "Moved Permanently";
    set obj.http.Location = "https://" req.http.host req.url;
    synthetic {""};
    return (deliver);
  } else if (obj.status == 750) {
    set obj.status = 301;
    set obj.response = "Moved Permanently";
    set obj.http.Location = req.http.x-redir;
    synthetic {""};
    return (deliver);
  }

  # Assume we've hit vcl_error() because the backend is unavailable
  # for the first two retries. By restarting, vcl_recv() will try
  # serving from stale before failing over to the mirrors.
  if (req.restarts < 3) {
    return (restart);
  }

  synthetic {"
    GOV.UK is experiencing technical difficulties now. Please try again later."};

  return (deliver);

#FASTLY error
}

# pipe cannot be included.

sub vcl_pass {
#FASTLY pass
}

sub vcl_hash {
#FASTLY hash
}
