#!/usr/bin/env python3
"""IT pub quiz MCP: 100 questions across Kubernetes, development and general IT.

Every quiz is ten questions drawn at random, steering clear of the ones used in the last few
quizzes. Nothing here reads data or changes anything, which is why its AgentRegistry record
carries mcp.governance/auto-approve=true.
"""
from collections import deque
import random
import threading
import time
import uuid

from mcp_base import serve

K, D, I = "kubernetes", "development", "it"
# (topic, question, options A-D, index of the right one, the line the host reads out after)
Q = [
    (K, "What is the smallest thing you can deploy in Kubernetes?", ["A container", "A pod", "A node", "A Deployment"], 1, "A pod wraps one or more containers that share a network and storage."),
    (K, "Which component stores all of a cluster's state?", ["kubelet", "kube-proxy", "etcd", "CoreDNS"], 2, "etcd is the key-value store behind the API server."),
    (K, "What is the default Service type?", ["NodePort", "ClusterIP", "LoadBalancer", "ExternalName"], 1, "ClusterIP gives a virtual IP reachable only inside the cluster."),
    (K, "Which flag lists pods in every namespace?", ["-a", "--everywhere", "-A", "-n *"], 2, "-A is short for --all-namespaces."),
    (K, "Why is Kubernetes shortened to k8s?", ["It was version 8", "There are 8 letters between the k and the s", "It had 8 founders", "It runs on port 8"], 1, "k, eight letters (ubernete), s."),
    (K, "Which object keeps a set number of identical pods running?", ["ConfigMap", "ReplicaSet", "Secret", "Ingress"], 1, "Deployments manage ReplicaSets, which keep the pod count right."),
    (K, "Which company originally designed Kubernetes?", ["Microsoft", "Red Hat", "Google", "Docker"], 2, "It grew out of Google's experience running Borg."),
    (K, "Which object holds non-secret configuration as key-value pairs?", ["ConfigMap", "Secret", "PersistentVolume", "ServiceAccount"], 0, "ConfigMaps are for settings you would not mind anyone reading."),
    (K, "Which agent on every node actually starts the pods?", ["kube-proxy", "kubelet", "etcd", "kube-scheduler"], 1, "The kubelet talks to the container runtime on its node."),
    (K, "Which component decides which node a new pod runs on?", ["kube-scheduler", "kubelet", "etcd", "kube-proxy"], 0, "The scheduler scores nodes and binds the pod to one."),
    (K, "In which year was Kubernetes 1.0 released?", ["2013", "2015", "2017", "2019"], 1, "Kubernetes 1.0 shipped in July 2015."),
    (K, "Which object runs one copy of a pod on every node?", ["Deployment", "StatefulSet", "DaemonSet", "Job"], 2, "DaemonSets suit log shippers and node agents."),
    (K, "Which object suits databases that need stable names and storage?", ["StatefulSet", "DaemonSet", "ReplicaSet", "CronJob"], 0, "StatefulSet pods keep their name and volume across restarts."),
    (K, "Which object runs a pod until its task finishes, then stops?", ["Deployment", "Job", "DaemonSet", "Service"], 1, "A Job runs to completion rather than forever."),
    (K, "Which object runs a Job on a schedule?", ["CronJob", "Timer", "ScheduledPod", "Crontab"], 0, "CronJob uses the same schedule syntax as cron."),
    (K, "What gives a set of pods a stable IP and DNS name?", ["An Ingress", "A Service", "A ConfigMap", "A Namespace"], 1, "Pods come and go; the Service address stays."),
    (K, "What splits one cluster into separate areas for different teams?", ["Nodes", "Labels", "Namespaces", "Annotations"], 2, "Namespaces scope names, quotas and access control."),
    (K, "What does HPA stand for?", ["High Performance API", "Horizontal Pod Autoscaler", "Host Port Allocation", "Helm Package Archive"], 1, "The HPA adds or removes pods based on metrics such as CPU."),
    (K, "Which probe tells Kubernetes a container is ready to receive traffic?", ["livenessProbe", "readinessProbe", "startupProbe", "healthProbe"], 1, "Until readiness passes, the pod is left out of the Service."),
    (K, "Which probe, when it fails, gets the container restarted?", ["readinessProbe", "livenessProbe", "trafficProbe", "exitProbe"], 1, "Liveness answers 'is it stuck?'."),
    (K, "What does the Kubernetes logo show?", ["An anchor", "A ship's wheel", "A lighthouse", "A whale"], 1, "A seven-spoked ship's wheel, a nod to its early codename Project Seven."),
    (K, "What does the Greek word Kubernetes mean?", ["Container", "Helmsman", "Cluster", "Shepherd"], 1, "Helmsman or pilot, the person who steers the ship."),
    (K, "Which command applies a manifest file to a cluster?", ["kubectl run -f", "kubectl apply -f", "kubectl push -f", "kubectl load -f"], 1, "apply creates the objects or updates them to match the file."),
    (K, "Where does kubectl look for its configuration by default?", ["/etc/kubectl.conf", "~/.kube/config", "~/.kubectl", "/var/kube/config"], 1, "You can point elsewhere with the KUBECONFIG variable."),
    (K, "What is known as the package manager for Kubernetes?", ["npm", "Helm", "apt", "Brew"], 1, "Helm packages manifests into charts."),
    (K, "What does CNCF stand for?", ["Cloud Native Computing Foundation", "Container Network Control Framework", "Central Node Cluster Forum", "Cloud Networking Core Federation"], 0, "The CNCF hosts Kubernetes, Prometheus, Envoy and many more."),
    (K, "What does a pod in CrashLoopBackOff mean?", ["It is waiting for a node", "It keeps crashing and Kubernetes waits longer between restarts", "It is being deleted", "It ran out of disk"], 1, "Check the logs of the previous run with kubectl logs --previous."),
    (K, "Which object is meant for passwords and tokens?", ["ConfigMap", "Secret", "Annotation", "Label"], 1, "Secrets are only base64 encoded by default, so encrypt them at rest."),
    (K, "Which port does the API server listen on by default in a kubeadm cluster?", ["443", "6443", "8080", "10250"], 1, "6443 is the kubeadm default; 10250 is the kubelet."),
    (K, "Which object routes outside HTTP traffic to Services by host and path?", ["Ingress", "Endpoint", "NetworkPolicy", "PodDisruptionBudget"], 0, "The Gateway API is its newer, more expressive successor."),
    (D, "What does HTTP status 404 mean?", ["Forbidden", "Not Found", "Server error", "Moved"], 1, "The server is fine; the thing you asked for is not there."),
    (D, "Which HTTP status code means 'I'm a teapot'?", ["404", "418", "451", "503"], 1, "An April Fools' RFC from 1998 that never went away."),
    (D, "What does HTTP status 500 mean?", ["Internal Server Error", "Not Found", "Unauthorised", "Too Many Requests"], 0, "Something broke on the server side."),
    (D, "What does HTTP status 201 mean?", ["OK", "Created", "Accepted", "No Content"], 1, "Usually the answer to a successful POST that made something."),
    (D, "What does HTTP status 301 mean?", ["Moved Permanently", "Not Modified", "Temporary Redirect", "Bad Request"], 0, "Browsers and search engines remember a 301."),
    (D, "Which Git command creates a new branch and switches to it?", ["git branch -d", "git checkout -b", "git merge", "git push -u"], 1, "git switch -c does the same in newer Git."),
    (D, "Which Git command shows the commit history?", ["git status", "git log", "git diff", "git show-branch"], 1, "Try git log --oneline --graph for the pretty version."),
    (D, "Who created Git?", ["Linus Torvalds", "Guido van Rossum", "Bill Gates", "Tim Berners-Lee"], 0, "He wrote it to manage Linux kernel development."),
    (D, "In which year was Git first released?", ["1999", "2005", "2010", "2014"], 1, "Git appeared in April 2005."),
    (D, "What does JSON stand for?", ["Java Standard Object Network", "JavaScript Object Notation", "Joined Serial Object Nodes", "JavaScript Online Node"], 1, "Despite the name, nearly every language reads it."),
    (D, "What does the DRY principle stand for?", ["Do Refactor Yearly", "Don't Repeat Yourself", "Deploy Right Yesterday", "Document Ready Yet"], 1, "Write each piece of knowledge once."),
    (D, "Which language was created by Guido van Rossum?", ["Ruby", "Python", "Perl", "Go"], 1, "Python 0.9 came out in 1991."),
    (D, "Which language is named after a comedy group?", ["Python", "Ruby", "Java", "Swift"], 0, "Named after Monty Python's Flying Circus, not the snake."),
    (D, "At which company was JavaScript created?", ["Microsoft", "Sun", "Netscape", "Google"], 2, "Brendan Eich wrote the first version in about ten days in 1995."),
    (D, "Which language has a gopher as its mascot?", ["Rust", "Go", "Kotlin", "Elixir"], 1, "The Go gopher was drawn by Renée French."),
    (D, "What is the name of Rust's unofficial crab mascot?", ["Ferris", "Crabby", "Rusty", "Clawd"], 0, "Rust users call themselves Rustaceans."),
    (D, "What does the recursive acronym YAML stand for today?", ["YAML Ain't Markup Language", "Your Application Markup Layer", "Yielded Array Markup List", "YAML Allows Many Lists"], 0, "It is a data format rather than a markup language."),
    (D, "What does REST stand for?", ["Remote Execution Service Transport", "Representational State Transfer", "Reliable Endpoint Server Technology", "Resource Encoding Standard Type"], 1, "From Roy Fielding's PhD thesis in 2000."),
    (D, "What does API stand for?", ["Application Programming Interface", "Automated Process Integration", "Advanced Protocol Internet", "App Platform Instance"], 0, "The contract one piece of software offers another."),
    (D, "What does SQL stand for?", ["Simple Query Logic", "Structured Query Language", "Server Queue Language", "Sequential Query Layer"], 1, "Some say 'sequel', some say S-Q-L. Both are fine."),
    (D, "What does CI/CD stand for?", ["Code Inspection / Code Delivery", "Continuous Integration / Continuous Delivery", "Container Image / Container Deploy", "Central Integration / Central Deployment"], 1, "The CD is sometimes read as Continuous Deployment."),
    (D, "What is a race condition?", ["A benchmark", "A bug where the result depends on the timing of concurrent work", "A fast CPU mode", "A CSS animation"], 1, "It works on your laptop and fails under load."),
    (D, "What does rubber duck debugging involve?", ["Testing in the bath", "Explaining your code, line by line, to a rubber duck", "A debugger called Duck", "Deleting code until it works"], 1, "Saying it out loud is often enough to spot the bug."),
    (D, "In semantic version 2.4.1, which number goes up for a breaking change?", ["The 2", "The 4", "The 1", "None of them"], 0, "MAJOR.MINOR.PATCH: breaking changes bump MAJOR."),
    (D, "How fast is binary search on a sorted list?", ["O(1)", "O(log n)", "O(n)", "O(n²)"], 1, "It halves the search space every step."),
    (D, "Which data structure is last in, first out?", ["Queue", "Stack", "Heap", "Linked list"], 1, "Like a stack of plates."),
    (D, "Which data structure is first in, first out?", ["Stack", "Queue", "Tree", "Graph"], 1, "Like the queue for coffee."),
    (D, "Which HTTP method should read data without changing anything?", ["POST", "GET", "DELETE", "PATCH"], 1, "GET should be safe to repeat."),
    (D, "npm is the default package manager for what?", ["Python", "Node.js", "Go", "Java"], 1, "It ships with Node.js."),
    (D, "Which book made 'Hello, World!' famous?", ["The C Programming Language", "Clean Code", "The Pragmatic Programmer", "Design Patterns"], 0, "Kernighan and Ritchie, 1978."),
    (D, "In a Dockerfile, what does the FROM line set?", ["The author", "The base image", "The exposed port", "The entry command"], 1, "Every image builds on top of another one, or on scratch."),
    (D, "What animal is Docker's mascot?", ["An octopus", "A whale", "A penguin", "A gopher"], 1, "A whale called Moby Dock, carrying containers."),
    (D, "In a code review, what does LGTM mean?", ["Let's Get The Merge", "Looks Good To Me", "Last Good Tested Master", "Log Gets Too Messy"], 1, "The two sweetest words a reviewer can type."),
    (D, "What does WIP mean on a pull request?", ["Work In Progress", "Wait, Important Patch", "Won't Implement, Probably", "Weekly Integration Plan"], 0, "Please do not merge it yet."),
    (D, "Which language runs natively in every web browser?", ["Java", "JavaScript", "C#", "Python"], 1, "WebAssembly runs there too, but it is a compile target."),
    (I, "Which port does HTTPS use by default?", ["80", "443", "8080", "22"], 1, "80 is plain HTTP."),
    (I, "Which port does plain HTTP use by default?", ["80", "443", "21", "25"], 0, "443 is the TLS version."),
    (I, "Which port does SSH use by default?", ["21", "22", "23", "25"], 1, "23 is Telnet, which you should not be using."),
    (I, "Which port does DNS use by default?", ["53", "67", "123", "161"], 0, "UDP mostly, TCP for large answers and zone transfers."),
    (I, "What does DNS translate?", ["IP addresses into MAC addresses", "Domain names into IP addresses", "Files into packets", "Emails into web pages"], 1, "The phone book of the internet."),
    (I, "How many bits are in a byte?", ["4", "8", "16", "32"], 1, "Half a byte is a nibble. Really."),
    (I, "What is 127.0.0.1 better known as?", ["The router", "localhost", "The DNS server", "The gateway"], 1, "There's no place like 127.0.0.1."),
    (I, "The first recorded computer 'bug' in 1947 was literally what?", ["A beetle", "A moth", "A spider", "A fly"], 1, "Grace Hopper's team taped it into the Harvard Mark II logbook."),
    (I, "What does SaaS stand for?", ["Storage as a Server", "Software as a Service", "Security as a Standard", "Systems and Automation Suite"], 1, "Also PaaS, IaaS and, apparently, everything-as-a-Service."),
    (I, "What does IP stand for in 'IP address'?", ["Internal Port", "Internet Protocol", "Instant Packet", "Integrated Path"], 1, "The protocol that moves packets between networks."),
    (I, "How many bits long is an IPv4 address?", ["16", "32", "64", "128"], 1, "About 4.3 billion addresses, which ran out."),
    (I, "How many bits long is an IPv6 address?", ["32", "64", "128", "256"], 2, "Enough for every grain of sand to have plenty."),
    (I, "What does VPN stand for?", ["Virtual Private Network", "Verified Public Node", "Very Protected Network", "Virtual Packet Navigator"], 0, "An encrypted tunnel over someone else's network."),
    (I, "What does RAM stand for?", ["Read Access Memory", "Random Access Memory", "Rapid Application Module", "Remote Array Memory"], 1, "Fast, and forgets everything when the power goes."),
    (I, "What does CPU stand for?", ["Central Processing Unit", "Core Power Unit", "Computer Primary Utility", "Central Program Uploader"], 0, "The part that does the sums."),
    (I, "What is phishing?", ["A network scan", "Tricking people into giving away passwords with fake messages", "A kind of firewall", "Backing up to tape"], 1, "Check the sender and hover before you click."),
    (I, "What does multi-factor authentication add to a password?", ["A longer password", "A second proof, such as a code or a key", "A security question", "A captcha"], 1, "Something you know plus something you have."),
    (I, "What does TLS stand for?", ["Transport Layer Security", "Trusted Link Service", "Total Line Safety", "Transfer Lock System"], 0, "The successor to SSL, and the S in HTTPS."),
    (I, "In which year was the first Linux kernel released?", ["1985", "1991", "1998", "2001"], 1, "Announced by a Finnish student as 'just a hobby'."),
    (I, "What is the name of the Linux penguin mascot?", ["Tux", "Pingu", "Linus", "Penny"], 0, "Drawn by Larry Ewing in 1996."),
    (I, "Finish the sysadmin haiku: 'It's not DNS / There's no way it's DNS / It was ...'", ["the firewall", "DNS", "a cable", "the intern"], 1, "It is always DNS."),
    (I, "What does ping measure?", ["Disk speed", "Whether a host answers and how long the round trip takes", "CPU temperature", "Wi-Fi strength"], 1, "Named after the sound of sonar."),
    (I, "What does URL stand for?", ["Uniform Resource Locator", "Universal Routing Link", "User Request Line", "Unified Remote Location"], 0, "The address you type into the browser."),
    (I, "What does HTML stand for?", ["HyperText Markup Language", "High Transfer Machine Language", "Hyperlink Text Mode Layout", "Home Tool Markup Language"], 0, "The skeleton of every web page."),
    (I, "Who invented the World Wide Web?", ["Bill Gates", "Tim Berners-Lee", "Vint Cerf", "Steve Jobs"], 1, "He proposed it in 1989."),
    (I, "Where was the World Wide Web invented?", ["MIT", "CERN", "Xerox PARC", "Bell Labs"], 1, "The physics lab near Geneva."),
    (I, "How many bytes are in a kibibyte (KiB)?", ["1000", "1024", "1048", "512"], 1, "A kilobyte (kB) is 1000; the binary one is 1024."),
    (I, "Which of these is not a cloud provider?", ["AWS", "Azure", "Google Cloud", "Kafka"], 3, "Kafka is an event streaming platform."),
    (I, "What does latency measure?", ["How much data fits in a link", "How long data takes to get there", "How many users are online", "How full the disk is"], 1, "Bandwidth is how wide the pipe is; latency is how long it is."),
    (I, "What does bandwidth measure?", ["Delay", "How much data can move per second", "Packet loss", "Signal colour"], 1, "Usually in megabits or gigabits per second."),
    (I, "About how much downtime a year does 99.9 percent uptime allow?", ["5 minutes", "52 minutes", "8.8 hours", "3.7 days"], 2, "Three nines is roughly 8 hours 46 minutes a year."),
    (I, "About how much downtime a year does 'five nines' (99.999 percent) allow?", ["5 minutes", "1 hour", "1 day", "1 week"], 0, "About 5 minutes 15 seconds a year."),
    (I, "Which TV show made 'Have you tried turning it off and on again?' famous?", ["The Office", "The IT Crowd", "Silicon Valley", "Mr. Robot"], 1, "Roy's answer to everything."),
    (I, "What does a CAPTCHA try to find out?", ["Your location", "Whether you are a human", "Your password strength", "Your browser version"], 1, "The H in CAPTCHA is for Humans."),
    (I, "What makes software open source?", ["It is free to download", "Its source code is published under a licence that lets anyone use, change and share it", "It runs on Linux", "It has no bugs"], 1, "Free as in freedom, not only as in beer."),
]
QUESTIONS = [
    {"id": f"q{i + 1:03d}", "topic": t, "question": q, "options": dict(zip("ABCD", o)),
     "answer": "ABCD"[a], "explanation": e}
    for i, (t, q, o, a, e) in enumerate(Q)
]
BY_ID = {q["id"]: q for q in QUESTIONS}
TOPICS = {K: "Kubernetes", D: "Development", I: "General IT"}
PER_QUIZ = 10
_rng = random.SystemRandom()
_lock = threading.Lock()
_recent = deque(maxlen=40)
_quizzes = {}


def _public(q, n, order):
    # order[i] is the canonical letter shown in position i, so each quiz reshuffles A to D.
    return {"number": n, "id": q["id"], "topic": TOPICS[q["topic"]], "question": q["question"],
            "options": {"ABCD"[i]: q["options"][c] for i, c in enumerate(order)}}


def _view(quiz, q):
    """The letters as this quiz showed them: {shown letter: canonical letter}."""
    order = (quiz or {}).get("order", {}).get(q["id"]) or list("ABCD")
    return {"ABCD"[i]: c for i, c in enumerate(order)}


def start_quiz(args):
    topic = (args.get("topic") or "mixed").strip().lower()
    if topic in ("k8s", "kube"):
        topic = K
    if topic in ("dev", "coding", "programming"):
        topic = D
    if topic in ("general", "general it", "general_it"):
        topic = I
    pool = [q for q in QUESTIONS if topic == "mixed" or q["topic"] == topic]
    if not pool:
        return {"error": "unknown topic", "topics": ["mixed", *TOPICS]}
    with _lock:
        fresh = [q for q in pool if q["id"] not in _recent]
        # Prefer questions nobody has seen in the last few quizzes; top up from the rest
        # when a single topic runs short.
        picks = _rng.sample(fresh, min(PER_QUIZ, len(fresh)))
        if len(picks) < PER_QUIZ:
            rest = [q for q in pool if q not in picks]
            picks += _rng.sample(rest, min(PER_QUIZ - len(picks), len(rest)))
        _recent.extend(q["id"] for q in picks)
        qid = uuid.uuid4().hex[:8]
        order = {q["id"]: _rng.sample("ABCD", 4) for q in picks}
        _quizzes[qid] = {"ids": [q["id"] for q in picks], "answers": {}, "order": order, "at": time.time()}
        if len(_quizzes) > 500:
            for old in sorted(_quizzes, key=lambda k: _quizzes[k]["at"])[:100]:
                _quizzes.pop(old, None)
    return {"quiz_id": qid, "topic": "Mixed" if topic == "mixed" else TOPICS[topic],
            "questions": [_public(q, i + 1, order[q["id"]]) for i, q in enumerate(picks)],
            "how_to_play": "Ask one question at a time. Send each answer to check_answer. Call quiz_score at the end."}


def check_answer(args):
    q = BY_ID.get(str(args.get("question_id", "")).strip())
    if not q:
        return {"error": "unknown question_id"}
    pick = str(args.get("answer", "")).strip().upper()[:1]
    if pick not in "ABCD" or not pick:
        return {"error": "answer must be A, B, C or D"}
    quiz = _quizzes.get(str(args.get("quiz_id", "")).strip())
    view = _view(quiz, q)
    shown = next(k for k, c in view.items() if c == q["answer"])
    right = view[pick] == q["answer"]
    out = {"question_id": q["id"], "your_answer": pick, "correct": right,
           "correct_answer": f"{shown}: {q['options'][q['answer']]}", "explanation": q["explanation"]}
    if quiz and q["id"] in quiz["ids"]:
        with _lock:
            quiz["answers"].setdefault(q["id"], right)
        got = sum(1 for v in quiz["answers"].values() if v)
        out["score_so_far"] = f"{got} out of {len(quiz['answers'])}"
    return out


def fifty_fifty(args):
    q = BY_ID.get(str(args.get("question_id", "")).strip())
    if not q:
        return {"error": "unknown question_id"}
    view = _view(_quizzes.get(str(args.get("quiz_id", "")).strip()), q)
    shown = next(k for k, c in view.items() if c == q["answer"])
    keep = sorted([shown, _rng.choice([k for k in "ABCD" if k != shown])])
    return {"question_id": q["id"], "remaining": {k: q["options"][view[k]] for k in keep}}


def quiz_score(args):
    quiz = _quizzes.get(str(args.get("quiz_id", "")).strip())
    if not quiz:
        return {"error": "unknown quiz_id. Start a new one with start_quiz."}
    got = sum(1 for v in quiz["answers"].values() if v)
    verdicts = [(10, "Perfect round. Drinks are on you."), (8, "Pub legend."), (6, "Solid. You can stay."),
                (4, "Respectable. Mostly."), (0, "It was DNS. It is always DNS.")]
    verdict = next(v for n, v in verdicts if got >= n)
    return {"quiz_id": str(args.get("quiz_id")).strip(), "answered": len(quiz["answers"]),
            "correct": got, "out_of": len(quiz["ids"]), "verdict": verdict}


def list_topics(_args):
    counts = {TOPICS[t]: sum(1 for q in QUESTIONS if q["topic"] == t) for t in TOPICS}
    return {"topics": {"mixed": len(QUESTIONS), **counts}, "per_quiz": PER_QUIZ}


TOOLS = [
    {"name": "start_quiz", "description": "Start a new round of 10 random questions. Topic: mixed (default), kubernetes, development or it.",
     "inputSchema": {"type": "object", "properties": {"topic": {"type": "string"}}}},
    {"name": "check_answer", "description": "Check an answer (A, B, C or D) and keep score for the quiz.",
     "inputSchema": {"type": "object", "properties": {"quiz_id": {"type": "string"}, "question_id": {"type": "string"},
                                                      "answer": {"type": "string"}}, "required": ["question_id", "answer"]}},
    {"name": "fifty_fifty", "description": "Take away two wrong answers from a question.",
     "inputSchema": {"type": "object", "properties": {"quiz_id": {"type": "string"}, "question_id": {"type": "string"}},
                     "required": ["question_id"]}},
    {"name": "quiz_score", "description": "Final score and verdict for a quiz.",
     "inputSchema": {"type": "object", "properties": {"quiz_id": {"type": "string"}}, "required": ["quiz_id"]}},
    {"name": "list_topics", "description": "Topics and how many questions each has.",
     "inputSchema": {"type": "object", "properties": {}}},
]
CALLS = {"start_quiz": start_quiz, "check_answer": check_answer, "fifty_fifty": fifty_fifty,
         "quiz_score": quiz_score, "list_topics": list_topics}

if __name__ == "__main__":
    serve("it-pub-quiz", TOOLS, CALLS)
