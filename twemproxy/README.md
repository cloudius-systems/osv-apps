### twemproxy on osv

Make change of nutcracker.yml by yourself and run:

```
capstan run
```

If you use the default config, the output should look like:

```
Building twemproxy...
Created instance: twemproxy
OSv v0.11
eth0: 192.168.122.15
[Wed Aug 13 19:18:54 2014] nc.c:187 nutcracker-0.3.0 built for Linux 3.7.0 x86_64 started on pid 0
[Wed Aug 13 19:18:54 2014] nc.c:192 run, rabbit run / dig that hole, forget the sun / and when at last the work is done / don't sit down / it's time to dig another one
[Wed Aug 13 19:18:54 2014] nc_core.c:43 max fds 10240 max client conns 10206 max server conns 2
[Wed Aug 13 19:18:54 2014] nc_stats.c:851 m 11 listening on '0.0.0.0:22222'
[Wed Aug 13 19:18:54 2014] nc_server.c:501 connect on s 18 to server '127.0.0.1:11212:1' failed: Connection refused
[Wed Aug 13 19:18:54 2014] nc_server.c:222 connect to server '127.0.0.1:11212:1' failed, ignored: Connection refused
[Wed Aug 13 19:18:54 2014] nc_proxy.c:206 p 18 listening on '127.0.0.1:22123' in memcache pool 0 'gamma' with 1 servers
[........................]
```
