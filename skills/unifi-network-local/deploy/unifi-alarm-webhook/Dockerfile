FROM python:3.12-alpine

WORKDIR /app
COPY skills/unifi-network-local/scripts/_paths.py /app/_paths.py
COPY skills/unifi-network-local/scripts/unifi_alarm_webhook_receiver.py /app/unifi_alarm_webhook_receiver.py

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV UNIFI_ALARM_WEBHOOK_BIND=0.0.0.0
ENV UNIFI_ALARM_WEBHOOK_PORT=8787
ENV UNIFI_ALARM_WEBHOOK_PATH=/webhook/unifi/alarm
ENV UNIFI_ALARM_LOKI_JOB=unifi_siem

EXPOSE 8787

CMD ["python3", "/app/unifi_alarm_webhook_receiver.py"]
