.PHONY: module
module: ec2-audit

CFLAGS = -std=gnu99 -O2 -Wall -Wextra -fpie

ec2-audit: ec2-audit.c
	$(CC) -pie -o $@ $(CFLAGS) $(LDFLAGS) ec2-audit.c

clean:
	rm -f ec2-audit
