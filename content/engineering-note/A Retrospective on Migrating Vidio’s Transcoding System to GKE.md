---
title: "Migrating Vidio’s Transcoding System to GKE: A Retrospective"
date: 2025-12-20
draft: false
---
***Disclaimer:** This article is a personal retrospective reconstructed from my own memory. At the time of writing, I no longer have access to Vidio’s internal documentation, source code, or design artifacts. Where exact details are uncertain, I intentionally use probabilistic language to reflect the limits of recall. The purpose of this writing is not to provide a precise historical record, but to reflect on the system, the migration process, and the engineering trade-offs involved during my time on Vidio’s video infra team.*

# **1\. Background**

Vidio is one of Indonesia’s largest OTT video streaming platforms, providing both Video-on-Demand (VOD) content, such as movies and television series, and Live Streaming (LS), including broadcast TV channels, sports events, and in-house productions.

Vidio operates as a subsidiary of SCTV, a major Indonesian television network under the EMTEK Group, one of the country’s largest media and technology conglomerates. Through this relationship, Vidio streams content from multiple EMTEK-owned channels such as SCTV and Indosiar, as well as international partners including DW, Arirang, NHK, and BEIN. Beyond broadcast television, Vidio also distributes licensed movies, series, partner content, and its own in-house productions under the “Vidio Original Series” brand.

Supporting these different kinds of content requires a robust video transcoding pipeline. Source media arrives in many forms, ranging from studio-produced files to live broadcast streams, and must be transformed into compressed, device-compatible formats suitable for delivery across a wide range of client platforms. Vidio client apps run on web browsers, Android and iOS devices, set-top boxes, and smart TVs, each with different playback capabilities and constraints.

As a result, the video transcoding system is not a peripheral component of Vidio’s platform, but a core part of its business infrastructure. It sits at the center of content ingestion, processing, and delivery, directly affecting reliability, cost, and user experience.

# **2\. The Transcoding Workflow at High Level**

Before discussing architecture or infrastructure, it helps to understand the overall shape of the video transcoding workflow at a high level. Vidio handled a wide variety of content sources, each driven by different business needs.

Vidio’s main content streaming systems can be broadly categorized into two types based on how the content is delivered to the viewer:

* **Video on Demand (VOD) streaming:** This is for pre-recorded videos that users can watch anytime.

* **Live streaming:** This system broadcasts content in real-time, such as TV channels, sports events, or gaming streams. Creators can stream from a webcam, mobile device, or through encoding software.

Technically, Vidio uses adaptive bitrate streaming for both systems so the quality adjusts automatically to the viewer’s internet connection. When a user clicks play, their device receives the video in small segments to be consumed smoothly by the players.

These content sources broadly fell into several categories. In practice, these sources often overlapped, but they represent the main categories the system had to support:

1. **File-based VOD sources**, including in-house productions, licensed movies, TV series, and Vidio Original Series. These assets were typically uploaded as raw video files through an internal web-based panel.

2. **User-generated or partner-uploaded content (UGC)**, which at the time was mostly used by internal teams for testing purposes and by selected content partners.

3. **Externally hosted content**, where some partners stored source media in external cloud storage or shared drives, which Vidio periodically scanned for new assets.

4. **Live broadcast streams** from SCTV and other EMTEK subsidiaries, originating from broadcast infrastructure and converted into RTMP streams.

5. **Live streams from external partners**, including local and international broadcasters and live content creators, using either broadcast-provided RTMP feeds or an internal live streaming panel similar to platforms like YouTube or Twitch.

6. **Recorded live events**, particularly high-demand sports events, where live streams were recorded and later converted into VOD for rewatching.

Despite these differences, content ingestion followed a small number of common patterns:

1. **API-triggered asynchronous jobs**, typically used for UGC and some partner uploads. After a source file was uploaded and stored in cloud storage, an API request would enqueue a transcoding job.

2. **Manually triggered jobs via internal admin panels**, used by content teams to reprocess, fix, or republish existing assets.

3. **Periodic or batch jobs**, which scanned external storage locations for newly added files and triggered transcoding accordingly.

4. **Internal async jobs**, used to derive VOD assets from recorded live streams. When a live stream was marked for recording, it produced a recording that later enqueued a transcoding job.

Regardless of the ingestion path, all content ultimately converged into a single asynchronous processing model. A central backend service published messages to a transcoding Message-Queue topic, which were then consumed by transcoding workers responsible for executing the rest of the pipeline.

# **3\. The Original Architecture**

Before the GKE migration, Vidio already used Google Cloud Platform across their deployment environment. Company-wide, we also maintain semi-homogeneous tech stacks, mainly Kotlin, Ruby and JavaScript.

## **3.1 The Components**

As I explained in the previous section, Vidio has two streaming systems, the VOD streaming and Live streaming. All of the components in both systems use Ruby, either Rails or Executable scripts.

### **3.1.1 VOD Streaming Components**

* **Job Tracker**: Tracks the progress of the transcoding. The only one that connects to the external database server, storing every transcoding information.

* **Chunker**: Downloads source media from object storage bucket. Prepares media for parallel transcoding.

* **Transcoder**: Core transcoding worker component. Transcodes the chunked source media.

* **Thumbnailer**: Creates thumbnail from transcoded video.

* **Packager**: Packages the source media into adaptive bitrate streaming formats, suitable to be consumed by players then uploads them to object storage bucket.

### **3.1.2 Live Streaming Components**

* **RTMP Server**: Main ingestion point. Receives RTMP streams from the broadcast team and Vidio’s main backend.

* **Transcoder**: Core transcoding worker component. Transcode the streams.

* **Packager**: Packages the source media into adaptive bitrate streaming formats, suitable to be consumed by players. Does not upload them.

* **Asset Uploader**: Watches the packaged outputs from packager then uploads it to an external memory cache server.

* **Recordings Uploader**: Archives some LS (sport matches) that are marked for recording. Uploads them to the object storage bucket.

* **Asset Server**: An HTTP web server. Serves assets produced by Packager requested by players. Retrieves them from the external memory cache server and writes them to the response body.

* **Metadata Server**: The only component in the LS transcoding pipeline which connects to the external database server. Stores information about codec profiles, bitrate ladder, and other metadata.

### **3.1.3 External Components (Not included in the migration)**

* **Main backend**: Handles everything else before the transcoding process: centralizes transcoding job requests from multiple source points. Sends transcoding jobs to Message Queue.

* **Message Queue (Google Pub/Sub)**: Receives VOD transcoding request from main backend. Pulled by Chunker.

* **Memory Cache Server**: Stores assets produced by Packager. Acts as a hot cache for low-latency delivery.

* **External Database**: Used by Job Tracker (VOD) and Metadata Server (LS). Stores persistent information related to transcoding.

* **Object Storage (Google Cloud Storage)**: Used by Chunker & Packager (VOD) and Recordings Uploader (LS). Stores blobs artifacts from both transcoding processes.

## **3.2 Compute & Deployment Model**

Within our video infra team, we utilize Google Compute Engine as our primary runtime. We have Jenkins to serve as our automation workflow, including CI & CD pipeline, in which testing and deployment are part of. This Jenkins was a shared internal tool across teams, with the video infra team maintaining its own deployment jobs and scripts.

Jenkins provided deployment jobs using Google Cloud CLI inside dedicated VM to do everything deployment-related:

1. Engineer triggers Jenkins job

2. Jenkins then :

   * Clones repository

   * Bakes VM image: Uses Ansible to build a new immutable GCE image containing the new code/config.

   * Creates Instance Template: generates a new GCE Instance Template version that references the newly baked-image’s ID

   * Roll managed instance group (MIG) for rolling update: Calls gcloud compute instance-groups managed rolling-action start-update.

3. GCE performs rolling updates and gradual VM replacement, replacing old VMs with new ones based on the new instance template.

   * Creating new VMs from the new template (Max Surge).

   * Taking old VMs offline (Max Unavailable).

   * Repeating this process until all VMs are updated.

The transcoding system has two dedicated instance groups, for primary and backup, respectively. Inside the provisioned VMs, transcoding workers ran as long-lived processes.

## **3.3 Language & Runtime**

Vidio’s video infra team chooses Ruby as the language of source code for the transcoder system. This is a monolithic repo which contains multiple Ruby scripts.

Other backend teams within Vidio had used Ruby since their inception, mainly for using Rails. To maximize development time and maintain organizational consistency the video infra team decided to also use Ruby. While Ruby was not optimized for CPU-intensive transcoding workloads, it was a reasonable choice at the time given organizational constraints. Ruby has been proven to increase development speed with its concise syntax, scripting nature, and rich ecosystem of gem libraries.

## **3.4 Job Orchestration**

As I described in the previous section, the Vidio’s business nature demands an asynchronous-capable system to perform transcoding across different kinds of sources.

For this purpose, the video infra team uses GCP’s Pub/Sub as our primary async backbone and Message Queue. Pub/Sub will handle transcoding job requests (using a predefined single-schema for contract) from these sources and store them centrally.

We also use Sidekiq as an upstream queue for transcoding jobs before Pub/Sub. This path was used selectively and did not represent the main transcoding workflow, mostly used in a specific ad-hoc, often urgent, one-off transcoding request.

For these special business cases, the workflow usually follows:

1. The Content team of PM requests, either directly to video infra engineers or proxied through Test Engineers.

2. The PM will make a story, marking it according to the urgency, that will be picked up by available video infra engineers / test engineers. The content team has to request the PM to make a story for them.

3. Test engineers then do pairing with video infra engineers to proceed the requests. One of them will supervise the other.

Sidekiq did not replace Pub/Sub. It acted as a control-plane entry point that ultimately published jobs into the same Pub/Sub-based execution pipeline.

The Sidekiq jobs are triggered via an internal web admin panel. The Ruby code that is executed by Sidekiq jobs will directly make requests to Pub/Sub. So these jobs will be executed in parallel with the request that is coming from web API.

# **4\. Operational Reality & Pain Points**

Operational responsibility was largely machine-centered: scaling decisions, deployments, and rollbacks were handled at the VM or instance group level rather than at the level of individual jobs.

As the volume and the type of workloads increased, this architecture began to show operational limits. Because deployment, scaling, and recovery were all tied to machine lifecycles rather than individual workloads, operational friction increased as the system grew, which later motivated changes.

## 

## **4.1 Deployment & Rollback**

Machine-centered VM deployments have their own benefits.

By nature it was predictable because the infrastructure model is more established and directly maps to physical hardware concepts. Each VM runs a complete, isolated guest OS, providing hardware-level isolation from other VMs on the same physical host. This dedicated environment ensures that one application’s resource consumption (CPU, memory, disk I/O) does not directly impact another’s. The application’s state and performance profile tend to drift less over time, this benefits workloads that do not require frequent scaling.

However, there are some pain points that we’ve experienced:

* **Resource Hogging:** Each VM runs a full OS (we used Ubuntu), consuming significant CPU, RAM, and storage.

* **Painful Rollbacks:** When something unexpected happened in application level and the engineer needs to rollback, the process involves manual works, such as:

  * Taking a snapshot of a working state or restoring from a prior image.

  * Coordinates with DevOps, Test Engineers, and On-Call Engineers to ensure data and config changes are compatible with the previous VM state. Sometimes using custom scripting if required.

While rollbacks were not frequent, the cost and coordination required when they did happen made engineers cautious about deploying changes.

## **4.2 Scaling & Cost**

While the resource one is not that much of a pain for the short term, it accumulates over time if there are many transcoding jobs. This is mostly felt during high-demand sports events, such as UEFA Champions League big matches. All backend teams will overprovision the VMs. These resulted in the cost spiking and was accepted as a trade-off for reliability during peak events.

## **4.3 Observability & Debugging**

Debugging and operational interventions often involved interacting directly with running instances (using SSH) and system behavior was primarily observed through machine-level metrics and logs.

This sometimes relies on the experience of specific engineers to diagnose complex issues spanning the OS, libraries, or application layers, as environments may not be fully consistent. We have many ops alerts but often are not helpful for explaining the root cause.

While this model was stable and predictable, it also meant that operational complexity increased as the system scaled.

## **4.4 Team Impact**

During this time, the knowledge around deployment mostly concentrates around DevOps and some Engineers and not-fully distributed among the team. The non-standardization nature of the VM-based deployment means when there is change, DevOps needs to communicate with the backend and test engineers. Onboarding new engineers is also difficult. Deployment playbooks exist but sometimes there are outdated points that the team forgot to update.

The lengthy and tedious process during rollback also often discourages engineers from deploying to production. This also slows down app development.

Though the system works, it feels fragile. Engineers were cautious about touching production in fear of breaking things and often required to perform long, tedious rollbacks when something unexpected happened.

These pain points did not indicate that the system was failing, but rather that it had reached the limits of a machine-centric deployment model. As Vidio continued to grow and as the organization began exploring container-based platforms across teams, these constraints set the stage for a broader architectural shift.

# **5\. Why the Migration Happened**

At this point the previous system served fairly well for both engineering and business purposes. The limitations described in the previous section were not the result of incorrect implementation, but rather rooted in structural constraints inherent to a machine-centric deployment model that had evolved over time.

During this time, other backend teams, as well as data, test, and mobile infra teams also experienced similar operational constraints, so containerization initiatives were being explored. As these constraints became more visible across teams, the organization began exploring alternative deployment models.

Software architects and the leadership evaluated the cost, operational and maintainability benefits of using container-based platforms. Based on the research at that time, Kubernetes (K8s) had emerged as a widely adopted standard. It provides primitives for horizontal scaling, workload isolation, and controlled rollouts.

As Vidio was already using GCP as the primary platform, and Google has its own managed-service for running Kubernetes orchestration called **Google Kubernetes Engine** (GKE), adopting it as the standardized migration platform was the preferred choice. Then the GKE migration initiatives began to be executed gradually and in parallel across the engineering teams.

Within the video infra team, a small migration group was formed consisting of two software engineers and one senior DevOps engineer. I was assigned alongside a more senior engineer, primarily due to my prior experience with CI/CD systems and documentation rather than any prior expertise with Docker or Kubernetes (as I had zero experience with either of them at that time). The DevOps engineer led the initiative and guided the implementation, while we worked closely through pair programming and incremental delivery. Vidio adopts pairing in their engineering culture, so member rotation within the team is encouraged. During migration, the migration group was expected to distribute knowledge to the rest of the video infra team via pairing.

# **6\. Migration**

For running transcoding jobs, the video infra team operated CPU-bound workloads that were bursty in nature. This made resource overprovisioning for high-spike events (like high-demand sports matches) costly, although acceptable as a trade-off. To mitigate this, we revisited the existing pipeline and we decided to introduce an additional component in the LS transcoding pipeline referred to internally as the Provisioner. This took the form of a custom internal web API that dynamically provisioned a dedicated Transcoder component per live stream.

Another critical constraint throughout the migration was the requirement for zero disruption to live streaming workloads. Live TV broadcasts and high-traffic events could not tolerate downtime. As a result, the migration had to coexist with ongoing live streams. This meant the migration strategy had to proceed incrementally and in parallel.

After the requirements were gathered, the team broke the initiative into smaller executable tasks and converted them into stories. These tasks were carefully created so that they could be taken without disrupting the ongoing feature development of the video infra team.

## **6.1 Scope & Sequence**

Because live streaming has higher demand than VOD, we decided to start with migrating the live streaming pipeline first, followed by the VOD streaming pipeline.

In the live streaming pipeline migration, a new component was introduced to manage per-stream provisioning. Its internal design is discussed in the next section.

In contrast to live streaming pipeline migration, the less bursty nature of VOD workloads does not require any special treatment. We decided to migrate the components by only writing Dockerfiles, Helm charts, and Kubernetes configurations without making changes to the core source codes.

## **6.2 Parallel-run strategy**

Parallel migration mainly concerned the LS pipeline. We began by creating a whitelist of which LS contents would be migrated first. The team coordinated with PMs and Live Ops. PMs gathered the list of LS content, they decided to choose low-traffic regional TV channels for the migration candidate. The remaining LS contents, especially the high-demand sports events and channels, stayed in the existing GCE-based pipeline.

After the team prepared all the Kubernetes infrastructure and ceremonies, we coordinated with Live Ops to roll out the whitelisted LS one by one. LiveOps had schedules in which the whitelisted LS had the lowest traffic. When LiveOps gave us notice, we prepared the rollout by switching the source of the LS to a temporary “Channel is under maintenance” banner. LiveOps then routed it to the new streaming RTMP ingest URL from the migrated LS pipeline. The order for the rollout is as follows: 

1. Deployed the staging version of Kubernetes LS transcoding pipeline   
2. Created a new streaming session for the whitelisted LS   
3. The Main backend sends a message to Pub/Sub requesting Kubernetes transcoding pipeline   
4. Set the maintenance banner to the targeted LS   
5. The LiveOps began routing the broadcast from the decoder to the newly created RTMP ingest URL from Kubernetes pipeline   
6. LiveOps monitor the quality of the stream using backdoor access   
7. The migration team monitors the metrics via metrics dashboard   
8. When the acceptance criteria were met, LiveOps lifted the maintenance banner 9\. Do the same for the production version of the LS transcoding pipeline

For the VOD, the rollout was easier. The migration team coordinated with PM and content team, as follows:

1. Deployed the staging version of Kubernetes VOD transcoding pipeline

2. Prepared a list of whitelisted content for migration.

3. Then activated a switch in the admin panel to make the main backend use the new Kubernetes transcoding pipeline.

4. The content team then began by re-transcode the whitelisted content one by one via admin panel

5. Migration team monitors the metrics via metrics dashboard

6. The content team checks the results via the normal Watch page.

7. When no issues were observed and acceptance criteria had passed, do the same step for the production version of the VOD transcoding pipeline \#\# 

## **6.3 Containerization Approach** 

For the containerization approach, we chose not to focus on optimization in the beginning. We began to choose an environment as close as possible to the existing transcoder VM. So we chose Ubuntu for the base images and installed dependencies similar to the ones provisioned to the VM.

The container for the rewritten transcoder of the LS pipeline dedicated to FFmpeg. It receives transcoding-related FFmpeg profiles that were parsed by Provisioner and injected during provisioning.

This was my first experience working with Docker and containerization while guided by the senior DevOps following the company standards.

### **6.3.1 Provisioner Component**

Provisioner has two internal endpoints: creates and delete, each to create and delete Transcoder components on demand. A high demand LS like sports will have higher specs than low-audience regional TV channels, for example.

The Provisioner would also separate between normal Transcoder and DRM transcoder. This separation is because they’re using different Packager (the next component after Transcoder in the pipeline). Separating them makes more sense to keep the container as light and stateless as possible.

### **6.3.2 Combining Live Stream’s Transcoder and Packager**

For the containerization, Transcoder and Packager have their own image. They were deployed together to preserve per-stream isolation requirements. A DRM-ed LS will have a different packager than the non-DRM LS.

### **6.3.3 Keeping other components**

For other components we only containerized them without any rewriting.

### **6.3.4 Changes in the Main backend**

The main backend which handles the user facing operations need to be made changes. The backend will now switch whether the new LS or VOD would use the new Kubernetes migrated pipeline or not. There are also changes in the Pub/Sub publisher as the Kubernetes pipeline uses different topics and subscriptions for transcoding than the old GCE pipeline.

## **6.4 Kubernetes Usage**

To minimize manual Ops, the company chose GKE as the Kubernetes platform. The DevOps team had already configured Helm and Helm charts to be used for company-wide migration, including for the video infra team. The video infra’s migration team only had to copy the provided helm chart template configs and adjust the values related to our requirements.

Most of the discussion with DevOps is around choosing node specifications for the Kubernetes Node. We begin by overprovisioning the specs, higher than the ones used in the VM pipeline. We can always optimize it later after migration.

## **6.5 Data & media flow adjustments during migration**

Much of the data and media flow weren’t changed compared to the VM-based pipelines. The ingestion still came from object storage buckets and RTMP streams. The method for transcoding process still uses local disk write and pipe to packaging process. Packagers for LS and VOD are still a separate process from transcoding. This was intentional, as preserving existing media handling behavior reduced migration risk. We focus on safety first during the migration.

## **6.6 Operational coordination** 

The migration involves close coordination with multiple teams: the PMs, Test engineers, Data, Content team, DevOps, LiveOps, other backend teams.

The main challenge was executing the migration while the company still scheduled many big live events. Coordinating with PMs and LiveOps to select the correct order of LS to migrate was a crucial point, as errors during the process could cause business damage. Fortunately, this task could be executed without major problems.

After the migration I was tasked with writing the playbooks for deployment of the video infra team’s components to the new GKE-based platforms. The senior engineer I was paired with moved to other major tasks.

During this time, the company also began adopting Backstage as the internal Developer portals. I decided to discuss with the team to move every documentation into Backstage so that it can be centralized. Previously, our docs were scattered around internal cloud drive files and repo wikis. I then closely paired with DevOps (the one who managed Backstage) to be guided around the standards.

## **6.7 What did *not* change**

During the evaluation period after migration, the migration team checked the outcomes.

The biggest changes mainly came from the increased deployment confidence: now the video infra team members were less afraid of deploying and doing rollbacks because it takes significantly less effort compared to previous VM-based ops.

However the targeted cost-effectiveness resulting from this migration hasn't been achieved yet. In theory, one Kubernetes node can replace multiple old VMs, packing many per-stream Transcoder Pods onto shared hardware without the overhead of duplicate OS kernels. The reality, after migration, the cost-effectiveness hasn’t dramatically changed from the old systems. This was mainly because we haven’t optimized the specs used by the containers. We put this into our next tasks.

Although the system had not yet reached its ideal state, this migration established a safer and more flexible execution model, which made subsequent iterations possible.

# **7\. Language & Worker Redesign**

During the migration, the team revisited the existing VM-based worker design. While Ruby had served the system well, certain characteristics of the transcoding workload became more relevant in a container-based environment, prompting limited and targeted language changes at the worker level.

## **7.1 Scope of language changes**

We limited the language changes to the worker-level components in the LS transcoding pipeline. This included the Transcoder, Packager, and the newly introduced Provisioner, while others remained in Ruby. The worker is the part of the pipeline that has the most frequent changes during development of the LS pipeline, mainly because the video infrastructure team kept researching the most efficient FFmpeg configurations.

The source code of the other parts of the pipeline were not touched and stayed in Ruby.

## **7.2 Why Ruby was still reasonable**

Ruby was the main programming language that was widely used across Vidio’s backend teams. The language had been used since Vidio’s inception. The reason was mostly because the team decided to use Rails for fast iteration, suitable for bootstrapping business. Ruby’s scripting proved to make live debugging in staging easier. During this time most Vidio backend engineers were already familiar with the language.

## **7.3 Why the worker workload pushed toward Go**

We decided to use Go because it can be compiled into one binary, making it portable and suitable for container-centric deployment as it offers more predictable startup behavior without a heavy language runtime dependency. In addition, it also provides a lightweight HTTP server (net/http) making it suitable for small internal services like transcoding pipeline components, without adding additional dependencies.

## **7.4 Worker redesign**

### **7.4.1 Creating Provisioner component**

We began by introducing a small internal service, referred to as the Provisioner. As mentioned in an earlier section, we introduced this small internal service responsible for coordinating worker instances per live stream.

The simplicity of Go's net/http suits the needs of Provisoner to be a small internal Web API which contains only two endpoints.

### **7.4.2 Rewriting Transcoder and Packager component**

For the Transcoder and Packager, we decided to rewrite them entirely with Go. This was because these components were simple and self-contained enough to be rewritten.

## **7.5 Concurrency model**

The Transcoder has a special task in the transcoding pipeline, which was to transcode the stream or file into separate resolution (e.g. 720p, 1080p) to enable Adaptive Bitrate Streaming (ABR).

For VOD transcoding happens offline with no real-time constraints, so resolutions can be processed one after another without impacting viewer experience, making parallelism beneficial for speed but not essential.

For live streaming, however, this is crucial because transcoding live streams to multiple resolutions is CPU-intensive, and running them sequentially would be too slow and cause high latency. Running them in parallel allowed better utilization of available CPU cores.

In the VM pipeline, there were two FFmpeg instances running inside the Transcoder VM, orchestrated by Ruby. While Ruby could spawn multiple FFmpeg processes, managing their lifecycles, coordination, and error handling became increasingly complex as concurrency requirements grew.

Go provided a concurrency model that made it easier to coordinate multiple FFmpeg subprocesses for different resolutions without adding orchestration complexity.

## **7.6 What did *not* improve**

As Go is a compiled language, the artifact was small and portable for deployment. However, debugging runtime errors is far easier in Ruby. In Go, you have to depend only on predetermined logs before compiling, while Ruby can facilitate live debugging to check uncovered places.

Go syntax was not as concise and readable as Ruby. Go’s verbose error handling, especially, while good for forcing the developer to be responsible for considering and addressing all possible failure points, sometimes making the code harder to scan compared to Ruby.

Even though Go’s scope is small enough in the pipeline, the video team felt this could affect maintainability in the future.

## **7.7 Lessons about language choice**

Introducing Go inside the transcoding pipeline exposed some caveats about designing a system. Different layers inside a system have different constraints and requirements. No matter how good a programming language syntax is, it can’t solve all runtime behaviors. Standardizing too early without making space for flexibility would have been a mistake for future use cases.

By introducing Go, the worker became easier to structure for parallel execution without additional orchestration complexity.

# **8\. Life After Migration & Outcomes**

The migration to Kubernetes was completed to be executed by incrementally making changes in parallel with production ops. After using it for several whitelisted contents, the system reached a new steady state and was gradually used for a broader set of workloads, including higher-demand content.

## **8.1 Deployment & rollback experience**

After completing the deployment playbook and the team has adopted it, the deployment felt noticeably easier than before. The coordination when a new feature wants to be deployed still needs LiveOps and Test Engineer awareness but much less tedious. The video infra team only needed to be aware of ongoing live events. Because the gradual worker instance replacement in GKE is quicker than GCE-orchestrated one, we can lift the maintenance banner quicker as well.

When something went wrong in production, rollback is now just a small configuration change. No need to take a snapshot of previous development which requires a complex process involving Jenkins. The video infrastructure team became less hesitant to touch production.

## **8.2 Scaling & resource utilization** 

Although the Kubernetes node specifications were not yet heavily optimized, at least now the video infra team had room to make improvements in that area.

The concurrency from switching to Go in LS transcoding workers appeared more predictable when observed through resource telemetry dashboards. The time between deployment and accepting streams appeared shorter in practice.

Resource requests and limits could be defined per workload, which gave the team more flexibility than the VM-based setup. Though the team still need to be cautious during peak events,

GKE also manages the node infrastructure. This reduced the need to overprovision entire VM instances compared to the previous setup, dynamically scaling capacity as needed. Workloads also could share node capacity more flexibly than in the VM-based setup.

## **8.3 Observability & debugging**

Observability shifted from machine-level inspection to workload-level inspection, with less reliance on SSH and more reliance on logs and metadata. This allowed the team to inspect logs and process-level metadata for individual containers more easily. The metadata provided by Kubernetes was also helpful during debugging.

Managing log agents in Kubernetes is also helped by a dedicated, managed agent (part of the node image) provided by GKE. It automatically deployed to each node in the GKE cluster. This reduced the operational burden of log collection compared to the VM-based setup.

However, because the container is not full OS-level instances, sometimes when the team needs certain linux tools, which commonly shipped along the standard OS installation, they forgot to install it in Dockerfile, and cannot be installed as easily as when using full OS

## **8.4 Team confidence & ownership**

After the migration, the documentation and playbooks I wrote in Backstage helped the team to distribute the knowledge among members. However, confidence lagged behind tooling.

Because Kubernetes is standardized, the team could now find information and helpful resources much easier from the internet. While deployments became more accessible, engineers still needed time to internalize the new operational model and failure modes.

## **8.5 What did *not* improve**

Some difficulties still remained after the migration. The deployment is more straightforward, but the development velocity for the video infra team remained much the same as before.

Some complexities still exist: Debugging Kubernetes requires new knowledge and methods that the team needs time to learn and get used to.

Because the flow of the pipeline had not changed much other than the LS pipeline, the existing complexities of the system did not disappear.

Some operational risk, mostly related to live streaming events ops, did not change. The video infra team needs to be aware of high peak events and check the autoscaling progresses, the bandwidth and other resource usages.

Introducing Go didn’t mean all the debugging became easier. It is just that now some errors can be safely guarded during compile time. Runtime errors, however, still remain and are now often harder to debug and need careful logging engineering in the source code.

## **8.6 Retrospective reflection**

The migration of Vidio’s transcoding pipeline to GKE reinforced several important observations. Incremental changes are crucial during the process. A repeated loop of introducing changes, testing them on a small subset of workloads, and evaluating outcomes contributed significantly to the migration’s success. This included introducing a new component (the Provisioner) and a new programming language. When something proved not worth the trade-off, the team could safely roll it back without major disruption. Another factor contributing to the migration’s success is primarily determined by a shared vision among the teams involved, clear purpose, and cultural cohesion, rather than the specific technology used (Kubernetes, GKE, Go).

As much as the infrastructure itself is important for business, the coordination between people involved in the migration also mattered.

## **8.7 Closing**

The migration to GKE marked the beginning of a longer transition rather than a final state. The transcoding system continued to evolve, and writing this retrospective allowed me to reconnect past decisions with a clearer present understanding of their impact.