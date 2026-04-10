FROM mcr.microsoft.com/azure-cli:latest

RUN tdnf install -y bind-utils && tdnf clean all

COPY aro-network-checker.sh /usr/local/bin/aro-network-checker.sh
RUN chmod +x /usr/local/bin/aro-network-checker.sh

ENTRYPOINT ["/usr/local/bin/aro-network-checker.sh"]
