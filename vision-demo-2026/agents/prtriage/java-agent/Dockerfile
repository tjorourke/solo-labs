# Built entirely in Docker, so no JDK or Maven is needed on the machine driving the demo.
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml .
# Fetch every dependency and plugin the build needs, in a layer keyed on pom.xml alone, so
# a source change does not refetch them. If this step fails, it fails here, while online.
RUN mvn -B -q -Dmaven.repo.local=/root/.m2 dependency:go-offline
COPY src ./src
# -o: offline. Everything is already in /root/.m2 from the layer above, so this step never
# asks the network for anything, and a source edit at a venue with no wifi still builds.
RUN mvn -B -o -Dmaven.repo.local=/root/.m2 package -DskipTests

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /src/target/prtriage-java.jar /app/app.jar
# The same approved skill the Python agent bakes in. One skill, two languages.
COPY skill.md /app/skill.md
ENV SKILL_PATH=/app/skill.md
# The MCP client library logs the server's entire instruction block at INFO, which is
# half a screen of noise before the demo output. Warn keeps the projector clean.
ENTRYPOINT ["java","-Dorg.slf4j.simpleLogger.defaultLogLevel=warn","-jar","/app/app.jar"]
