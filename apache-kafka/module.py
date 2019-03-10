from osv.modules import api

api.require('java8')

default = api.run(
    '--cwd=/kafka '
    '/java.so '
    '-Xmx1G '
    '-Xms1G '
    '-XX:+UseParNewGC '
    '-XX:+UseConcMarkSweepGC '
    '-XX:+CMSClassUnloadingEnabled '
    '-XX:+CMSScavengeBeforeRemark '
    '-XX:+DisableExplicitGC '
    '-Djava.awt.headless=true '
    '-Xloggc:/kafka/logs/kafkaServer-gc.log '
    '-verbose:gc '
    '-XX:+PrintGCDetails '
    '-XX:+PrintGCDateStamps '
    '-XX:+PrintGCTimeStamps '
    '-Dcom.sun.management.jmxremote '
    '-Dcom.sun.management.jmxremote.authenticate=false '
    '-Dcom.sun.management.jmxremote.ssl=false '
    '-Dkafka.logs.dir=/kafka/logs '
    '-Dlog4j.configuration=file:/kafka/config/log4j.properties '
    '-cp :/kafka/libs/* '
    'kafka.Kafka /kafka/config/server.properties'
)
