FROM python:3.11-slim

WORKDIR /app
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    wget \
    gnupg2 \
    lsb-release \
    curl \
    ca-certificates \
    && wget https://repo.percona.com/apt/percona-release_latest.$(lsb_release -sc)_all.deb \
    && dpkg -i percona-release_latest.$(lsb_release -sc)_all.deb \
    && percona-release setup ps80 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
    mydumper \
    percona-xtrabackup-80 \
    && rm -rf /var/lib/apt/lists/* \
    && rm percona-release_latest.*.deb
COPY . .
RUN pip install --no-cache-dir -r pkgpy/requirements.txt

EXPOSE 8000

CMD ["uvicorn", "pkgpy.main:app", "--host", "0.0.0.0", "--port", "8000"]

