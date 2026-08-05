(require 'cemerick.pomegranate.aether)
(require 'clojure.string)
(cemerick.pomegranate.aether/register-wagon-factory!
 "http" #(org.apache.maven.wagon.providers.http.HttpWagon.))

(defproject greenways/ignatius "0.1.0-SNAPSHOT"
  :description "PostgreSQL adapter for the Ignatius Hara chain"
  :url "https://github.com/greenways-ai/ignatius"
  :license {:name "Apache License 2.0"
            :url "https://www.apache.org/licenses/LICENSE-2.0"}
  :aliases
  {"test"     ["run" "-m" "code.test"]
   "manage"   ["run" "-m" "code.manage"]
   "sql"      ["run" "-m" "ledger.build-sql"]
   "contracts" ["run" "-m" "ledger.build-contract"]
   }
  :dependencies [[org.clojure/clojure "1.11.1"]
                 [org.xerial/sqlite-jdbc   "3.36.0.3"]
                 [org.clojure/java.jdbc    "0.7.12"]
                 
                 ;; 
                 [org.clojure/data.json    "2.4.0"]
                 [http-kit                 "2.8.0"]
                 [clj-kondo/clj-kondo      "2024.09.27"]
                 [com.googlecode.java-diff-utils/diffutils "1.3.0"]
                 [com.fasterxml.jackson.core/jackson-core "2.16.1"]
                 [com.fasterxml.jackson.core/jackson-databind "2.16.1"]
                 [com.fasterxml.jackson.datatype/jackson-datatype-jsr310 "2.16.1"]
                 [org.jsoup/jsoup "1.17.2"]
                 
                 ;; mcp server
                 ;; [cheshire "5.13.0"]
                 ;; [com.fasterxml.jackson.core/jackson-core "2.20.0"]
                 ;; [com.fasterxml.jackson.core/jackson-databind "2.15.2"]
                 ;; [io.modelcontextprotocol.sdk/mcp "0.11.2"]
                 ;; [io.modelcontextprotocol.sdk/mcp-spring-webflux "0.11.2"]
                 ;; [org.springframework/spring-webflux "6.0.11"]
                 ;; [org.springframework/spring-context "6.0.11"]
                 ;; [io.projectreactor.netty/reactor-netty "1.1.9"]
                 ;; [hato/hato "1.0.0"]
                 ;; [org.slf4j/slf4j-simple "2.0.13"]
                 ;; -- end mcp

                 [org.ow2.asm/asm "9.7.1"]
                 [org.postgresql/postgresql "42.7.2"]
                 [borkdude/edamame "1.4.24"]]
  :profiles {:dev {:plugins [[lein-ancient "0.6.15"]
                             [lein-exec "0.3.7"]
                             [lein-cljfmt "0.7.0"]
                             [cider/cider-nrepl "0.58.0"]
                             [lein-dotenv "RELEASE"]]}
             :mcp {:plugins [[lein-mcp "0.1.0-SNAPSHOT"]]}
             :repl {:injections [(try (require '[std.lib :as h])
                                      (require 'jvm.tool)
                                      (catch Throwable t (.printStackTrace t)))]}}  
  :resource-paths    ["resources"
                      "src"
                      "test"
                      "checkouts/foundation/resources"
                      "checkouts/foundation/src-build"
                      "checkouts/foundation/src-extra"
                      "checkouts/foundation/src-doc"
                      "checkouts/foundation/test-data"
                      "checkouts/foundation/test-code"]
  :source-paths      ["src"
                      "src-mcp"
                      "checkouts/foundation/src"
                      "checkouts/foundation/src-lang"
                      "checkouts/foundation/src-extra"
                      "checkouts/foundation/src-extra/mcp-clj"]
  :java-source-paths ["checkouts/foundation/src-java/hara/lib/concurrent"
                      "checkouts/foundation/src-java/hara/lib/foundation"
                      "checkouts/foundation/src-java/hara/lib/json"]
  :test-paths        ["test"]                                            
  :repl-options {:host "0.0.0.0" :port 10234}
  :jvm-opts
  ["-Xms2048m"
   "-Xmx2048m"
   "-XX:MaxMetaspaceSize=1048m"
   "-XX:-OmitStackTraceInFastThrow"
   
   ;;
   ;; GC FLAGS
   ;;
   "-XX:+UseAdaptiveSizePolicy"
   "-XX:+AggressiveHeap"
   "-XX:+ExplicitGCInvokesConcurrent"
   ;;"-XX:+UseCMSInitiatingOccupancyOnly"
   ;;"-XX:+CMSClassUnloadingEnabled"
   ;;"-XX:+CMSParallelRemarkEnabled"

   ;;
   ;; GC TUNING
   ;;   
   "-XX:MaxNewSize=256m"
   "-XX:NewSize=256m"
   ;;"-XX:CMSInitiatingOccupancyFraction=60"
   "-XX:MaxTenuringThreshold=8"
   "-XX:SurvivorRatio=4"

   ;;
   ;; Truffle
   ;;
   "-Dpolyglot.engine.WarnInterpreterOnly=false"
   
   ;;
   ;; JVM
   ;;
   "-Djdk.tls.client.protocols=\"TLSv1,TLSv1.1,TLSv1.2\""
   "-Djdk.attach.allowAttachSelf=true"
   ;; "-Djava.net.preferIPv4Stack=true"
   "--enable-native-access=ALL-UNNAMED"
   "--add-opens" "java.base/java.io=ALL-UNNAMED"
   "--add-opens" "java.base/java.lang=ALL-UNNAMED"
   "--add-opens" "java.base/java.lang.annotation=ALL-UNNAMED"
   "--add-opens" "java.base/java.lang.invoke=ALL-UNNAMED"
   "--add-opens" "java.base/java.lang.module=ALL-UNNAMED"
   "--add-opens" "java.base/java.lang.ref=ALL-UNNAMED"
   "--add-opens" "java.base/java.lang.reflect=ALL-UNNAMED"
   "--add-opens" "java.base/java.math=ALL-UNNAMED"
   "--add-opens" "java.base/java.net=ALL-UNNAMED"
   "--add-opens" "java.base/java.nio=ALL-UNNAMED"
   "--add-opens" "java.base/java.nio.channels=ALL-UNNAMED"
   "--add-opens" "java.base/java.nio.charset=ALL-UNNAMED"
   "--add-opens" "java.base/java.nio.file=ALL-UNNAMED"
   "--add-opens" "java.base/java.nio.file.attribute=ALL-UNNAMED"
   "--add-opens" "java.base/java.nio.file.spi=ALL-UNNAMED"
   "--add-opens" "java.base/java.security=ALL-UNNAMED"
   "--add-opens" "java.base/java.security.cert=ALL-UNNAMED"
   "--add-opens" "java.base/java.security.interfaces=ALL-UNNAMED"
   "--add-opens" "java.base/java.security.spec=ALL-UNNAMED"
   "--add-opens" "java.base/java.text=ALL-UNNAMED"
   "--add-opens" "java.base/java.time=ALL-UNNAMED"
   "--add-opens" "java.base/java.time.chrono=ALL-UNNAMED"
   "--add-opens" "java.base/java.time.format=ALL-UNNAMED"
   "--add-opens" "java.base/java.time.temporal=ALL-UNNAMED"
   "--add-opens" "java.base/java.time.zone=ALL-UNNAMED"
   "--add-opens" "java.base/java.util=ALL-UNNAMED"
   "--add-opens" "java.base/java.util.concurrent=ALL-UNNAMED"
   "--add-opens" "java.base/java.util.concurrent.atomic=ALL-UNNAMED"
   "--add-opens" "java.base/java.util.concurrent.locks=ALL-UNNAMED"
   "--add-opens" "java.base/java.util.function=ALL-UNNAMED"
   "--add-opens" "java.base/java.util.jar=ALL-UNNAMED"
   "--add-opens" "java.base/java.util.regex=ALL-UNNAMED"
   "--add-opens" "java.base/java.util.spi=ALL-UNNAMED"
   "--add-opens" "java.base/java.util.stream=ALL-UNNAMED"
   "--add-opens" "java.base/java.util.zip=ALL-UNNAMED"
   "--add-opens" "java.base/jdk.internal=ALL-UNNAMED"
   "--add-opens" "java.base/jdk.internal.loader=ALL-UNNAMED"
   "--add-opens" "java.base/jdk.internal.misc=ALL-UNNAMED"
   "--add-opens" "java.base/jdk.internal.module=ALL-UNNAMED"
   "--add-opens" "java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED"
   "--add-opens" "java.base/jdk.internal.org.xml.sax=ALL-UNNAMED"
   "--add-opens" "java.base/jdk.internal.perf=ALL-UNNAMED"
   "--add-opens" "java.base/jdk.internal.reflect=ALL-UNNAMED"
   "--add-opens" "java.base/jdk.internal.util=ALL-UNNAMED"
   "--add-opens" "java.base/jdk.internal.vm=ALL-UNNAMED"
   "--add-opens" "java.base/jdk.internal.vm.annotation=ALL-UNNAMED"

   "--add-opens" "java.net.http/java.net.http=ALL-UNNAMED"
   "--add-opens" "java.net.http/jdk.internal.net.http=ALL-UNNAMED"
   "--add-opens" "java.management/java.lang.management=ALL-UNNAMED"
   "--add-opens" "java.management/sun.management=ALL-UNNAMED"])
