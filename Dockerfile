
FROM ubuntu

RUN apt-get -yqq update       \
 && apt-get -yqq install wget \
 && rm -rf /var/lib/apt/lists/*

RUN RELEASES='https://github.com/Yelp/dumb-init/releases/download' \
 && wget -O /usr/local/bin/dumb-init "$RELEASES/v1.2.2/dumb-init_1.2.2_amd64" \
 && chmod +x /usr/local/bin/dumb-init

COPY entrypoint.bash .

ENTRYPOINT ["/usr/local/bin/dumb-init", "--", "bash", "entrypoint.bash"]
CMD ["--help"]
