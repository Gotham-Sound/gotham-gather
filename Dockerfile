FROM python:3.12-slim

# runtime tools the gather engine shells out to
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl rsync smbclient cifs-utils samba-common-bin rclone ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*

# Match the studio's local time so "today's shoot" detection works in the evening
# (gear stamps local time; a UTC container rolls over to tomorrow after ~8pm EDT).
ENV TZ=America/New_York

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY bin ./bin
RUN chmod +x bin/gather.sh

ENV ISOS_SHARE=/data/isos \
    GATHER_SH=/app/bin/gather.sh \
    CARDS_DIR=/data/cards \
    PYTHONUNBUFFERED=1

EXPOSE 8787
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8787"]
