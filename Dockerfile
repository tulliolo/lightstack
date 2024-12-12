FROM debian:12.6-slim
RUN apt-get update
RUN apt-get install -y curl wget unzip libcurl4-gnutls-dev libsqlite3-dev


WORKDIR /app
RUN 	cd /app && wget https://github.com/ACINQ/phoenixd/releases/download/v0.4.2/phoenix-0.4.2-linux-x64.zip &&\
	unzip -j phoenix-0.4.2-linux-x64.zip 


CMD [ "./phoenixd" ]

