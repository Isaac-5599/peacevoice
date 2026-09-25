#!/usr/bin/env ruby
# PeaceVoice — Community platform for peace, justice, and strong institutions (SDG 16)

# Render's start command runs this file without `bundle exec`, so activate
# Bundler here; local dev on old Ruby without the bundled gems uses system gems.
begin
  require 'bundler/setup'
rescue LoadError, StandardError
  ENV.delete('GEM_HOME')
  ENV.delete('GEM_PATH')
  ENV.delete('BUNDLE_PATH')
  Gem.clear_paths
  Gem::Specification.reset
end

require 'webrick'
require 'sqlite3'
require 'json'
require 'securerandom'
require 'digest'
require 'time'

BASE_DIR = File.dirname(File.expand_path(__FILE__))
PUBLIC_DIR = File.join(BASE_DIR, 'public')
DB_PATH = File.join(BASE_DIR, 'peacevoice.db')
PORT = (ENV['PORT'] || 3000).to_i

# ─── Session Store ───────────────────────────────────────────────────────────

$sessions = {} # session_id => { user_id:, role:, expires: }

def create_session(user_id, role)
  sid = SecureRandom.hex(32)
  $sessions[sid] = { user_id: user_id, role: role, expires: Time.now + 7 * 86400 }
  sid
end

def get_session(sid)
  return nil unless sid && $sessions[sid]
  s = $sessions[sid]
  if s[:expires] > Time.now
    s
  else
    $sessions.delete(sid)
    nil
  end
end

def hash_password(password, salt = nil)
  salt ||= SecureRandom.hex(16)
  h = Digest::SHA256.hexdigest(salt + password)
  "#{salt}:#{h}"
end

def verify_password(password, stored)
  salt, h = stored.split(':', 2)
  Digest::SHA256.hexdigest(salt + password) == h
end

# ─── Database ────────────────────────────────────────────────────────────────

def get_db
  db = SQLite3::Database.new(DB_PATH)
  db.results_as_hash = true
  db.execute("PRAGMA journal_mode = WAL")
  db.execute("PRAGMA foreign_keys = ON")
  db
end

def row(d)
  return nil unless d
  d.is_a?(Array) ? d.first : d
end

def init_db
  db = get_db
  db.execute_batch <<-SQL
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT UNIQUE NOT NULL,
      email TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL,
      display_name TEXT NOT NULL,
      bio TEXT DEFAULT '',
      avatar_color TEXT DEFAULT '#3B82F6',
      role TEXT DEFAULT 'user',
      created_at TEXT DEFAULT (datetime('now'))
    );
    CREATE TABLE IF NOT EXISTS forum_categories (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT UNIQUE NOT NULL,
      description TEXT,
      icon TEXT,
      sort_order INTEGER DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS forum_threads (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      category_id INTEGER REFERENCES forum_categories(id),
      user_id INTEGER REFERENCES users(id),
      title TEXT NOT NULL,
      content TEXT NOT NULL,
      is_pinned INTEGER DEFAULT 0,
      is_locked INTEGER DEFAULT 0,
      created_at TEXT DEFAULT (datetime('now')),
      updated_at TEXT DEFAULT (datetime('now'))
    );
    CREATE TABLE IF NOT EXISTS forum_replies (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      thread_id INTEGER REFERENCES forum_threads(id) ON DELETE CASCADE,
      user_id INTEGER REFERENCES users(id),
      content TEXT NOT NULL,
      created_at TEXT DEFAULT (datetime('now'))
    );
    CREATE TABLE IF NOT EXISTS petitions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER REFERENCES users(id),
      title TEXT NOT NULL,
      description TEXT NOT NULL,
      target_entity TEXT,
      goal_signatures INTEGER DEFAULT 100,
      status TEXT DEFAULT 'open',
      created_at TEXT DEFAULT (datetime('now'))
    );
    CREATE TABLE IF NOT EXISTS petition_signatures (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      petition_id INTEGER REFERENCES petitions(id) ON DELETE CASCADE,
      user_id INTEGER REFERENCES users(id),
      created_at TEXT DEFAULT (datetime('now')),
      UNIQUE(petition_id, user_id)
    );
    CREATE TABLE IF NOT EXISTS events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER REFERENCES users(id),
      title TEXT NOT NULL,
      description TEXT NOT NULL,
      event_type TEXT DEFAULT 'other',
      location TEXT,
      is_virtual INTEGER DEFAULT 0,
      virtual_link TEXT,
      event_date TEXT NOT NULL,
      end_date TEXT,
      max_attendees INTEGER DEFAULT 0,
      status TEXT DEFAULT 'upcoming',
      created_at TEXT DEFAULT (datetime('now'))
    );
    CREATE TABLE IF NOT EXISTS event_rsvps (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      event_id INTEGER REFERENCES events(id) ON DELETE CASCADE,
      user_id INTEGER REFERENCES users(id),
      created_at TEXT DEFAULT (datetime('now')),
      UNIQUE(event_id, user_id)
    );
    CREATE TABLE IF NOT EXISTS resources (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      description TEXT NOT NULL,
      content TEXT,
      resource_type TEXT DEFAULT 'article',
      category TEXT DEFAULT 'peace',
      external_url TEXT,
      author_name TEXT,
      created_at TEXT DEFAULT (datetime('now'))
    );
  SQL

  count = db.execute("SELECT COUNT(*) as c FROM users").first["c"]
  seed_database(db) if count == 0
  db
end

def seed_database(db)
  pw = hash_password('password123')
  colors = ['#3B82F6', '#059669', '#F59E0B', '#EF4444', '#8B5CF6', '#EC4899']

  users = [
    ['admin', 'admin@peacevoice.org', 'Admin', 'Platform administrator for PeaceVoice.', colors[0], 'admin'],
    ['maria_santos', 'maria@example.com', 'Maria Santos', 'Human rights advocate and community organizer.', colors[1], 'user'],
    ['james_okoro', 'james@example.com', 'James Okoro', 'Legal aid volunteer passionate about access to justice.', colors[2], 'user'],
    ['priya_sharma', 'priya@example.com', 'Priya Sharma', 'Journalist covering government transparency.', colors[3], 'user'],
    ['david_chen', 'david@example.com', 'David Chen', 'Civic tech developer and open data advocate.', colors[4], 'user'],
    ['amara_diallo', 'amara@example.com', 'Amara Diallo', 'Peace education researcher.', colors[5], 'user'],
  ]
  users.each { |u| db.execute("INSERT INTO users (username,email,password_hash,display_name,bio,avatar_color,role) VALUES (?,?,?,?,?,?,?)", u[0..1] + [pw] + u[2..-1]) }

  cats = [
    ['Peacebuilding', 'Discussions on conflict resolution, reconciliation, and building lasting peace.', "\u{1F54A}\u{FE0F}", 1],
    ['Justice & Human Rights', 'Topics on legal access, human rights protection, and equality before the law.', "\u{2696}\u{FE0F}", 2],
    ['Government Accountability', 'Holding institutions and officials accountable to the public.', "\u{1F3DB}\u{FE0F}", 3],
    ['Rule of Law', 'Strengthening legal frameworks and ensuring equal access to justice.', "\u{1F4DC}", 4],
    ['Community Safety', 'Building safer communities through cooperation and trust.', "\u{1F91D}", 5],
  ]
  cats.each { |c| db.execute("INSERT INTO forum_categories (name,description,icon,sort_order) VALUES (?,?,?,?)", c) }

  threads = [
    [1,2,'How can we promote dialogue between conflicting communities?','I have been working on inter-community dialogue programs and wanted to share some approaches that have worked. Restorative justice circles, shared community projects, and youth exchange programs have all shown promise in my experience. What methods have you found effective?',1,'-5 days'],
    [2,3,'Legal aid deserts: what can we do about unequal access?','Many rural communities have virtually no legal aid available. People facing eviction, domestic violence, or wrongful termination simply cannot find representation. I think mobile legal clinics and pro bono networks could help. Thoughts?',0,'-3 days'],
    [3,4,'Tracking government spending: tools and techniques','I have been experimenting with open data portals and FOIA requests to track how public funds are allocated. Some governments publish detailed spending data, but much of it is buried in PDFs. Lets discuss tools for making this data accessible.',0,'-4 days'],
    [1,6,'Peace education in schools: a curriculum proposal','I have been developing a peace education curriculum for middle schoolers that covers conflict resolution, media literacy, and empathy building. Early pilot results are promising. Would love feedback from educators in this community.',0,'-2 days'],
    [4,3,'Reforming bail systems: progress and setbacks','Cash bail disproportionately impacts low-income defendants. Some jurisdictions have made progress with risk assessment tools, but these come with their own biases. What alternatives have shown the most promise?',0,'-6 days'],
    [5,5,'Community policing: building trust from the ground up','After attending several community policing forums, I believe the model has potential but needs structural support. Officers need training in de-escalation, and communities need real oversight power.',0,'-1 day'],
    [2,4,'Freedom of information: how to file effective requests','Many people do not realize they have a right to request government documents. I have put together a guide on how to write clear, specific FOIA requests that are more likely to get useful responses.',1,'-7 days'],
    [3,5,'Open-source tools for government transparency','As a developer, I believe we can build tools that make government data more accessible. Think dashboards for tracking legislation, budget visualizations, and alert systems for policy changes. Who wants to collaborate?',0,'-3 days'],
    [1,2,'Reconciliation after conflict: lessons from around the world','Studying truth and reconciliation processes from South Africa, Rwanda, and Colombia has given me insights into what works and what does not. The most successful processes center victims and include community-level dialogue.',0,'-4 days'],
    [4,6,'Environmental justice and the rule of law','Communities near polluting industries often lack legal recourse. Environmental justice intersects with racial and economic justice in critical ways.',0,'-2 days'],
    [5,2,'Youth violence prevention: what the research says','Research consistently shows that investment in education, mentorship, and economic opportunity reduces youth violence more effectively than punitive measures.',0,'-5 days'],
    [2,4,'Digital rights are human rights','Internet access, data privacy, and freedom of expression online are increasingly recognized as human rights issues. How should we approach digital rights advocacy in the context of SDG 16?',0,'-1 day'],
    [3,5,'Whistleblower protections: where we stand','Strong whistleblower protections are essential for government accountability, yet many who expose wrongdoing face retaliation.',0,'-6 days'],
  ]
  threads.each { |t| db.execute("INSERT INTO forum_threads (category_id,user_id,title,content,is_pinned,created_at) VALUES (?,?,?,?,?,datetime('now',?))", t) }

  replies = [
    [1,3,'Restorative justice circles have been transformative in my community. The key is ensuring all parties feel heard and that outcomes are actionable, not just symbolic.','-4 days'],
    [1,5,'Shared community projects are brilliant. When people from different backgrounds work together on a garden or a food bank, barriers break down naturally.','-4 days'],
    [1,4,'Youth exchange programs changed my perspective growing up. I think starting dialogue early is crucial.','-3 days'],
    [2,2,'Mobile legal clinics are a great idea. In my area, law schools have started sending students to rural areas under supervision.','-2 days'],
    [2,6,'The lack of legal aid is a systemic failure. We need policy change, not just band-aid solutions.','-2 days'],
    [2,5,'I have been working on a tech platform that matches pro bono lawyers with people in need. The response has been encouraging.','-1 day'],
    [3,2,'Great topic! I have used OpenRefine for cleaning up government PDF data. Its free and powerful once you learn the basics.','-3 days'],
    [3,6,'The challenge is not just getting the data but making it understandable for the average citizen.','-3 days'],
    [4,3,'This curriculum sounds wonderful. Can you share the pilot results?','-1 day'],
    [4,5,'Media literacy is so important right now. Young people need tools to evaluate information critically.','-1 day'],
    [5,4,'Risk assessment tools can encode existing biases if not carefully designed.','-5 days'],
    [5,2,'The most promising alternative is supervised release with support services rather than detention based on ability to pay.','-4 days'],
    [6,3,'Community oversight boards with real authority are essential. Advisory-only boards tend to become toothless.','-1 day'],
    [7,5,'Your guide is excellent! One tip: always request records in a specific format (like CSV).','-6 days'],
    [8,3,'Count me in for collaboration. I have experience with data visualization.','-2 days'],
    [8,6,'We should also think about non-technical users. Plain-language summaries would be incredibly valuable.','-2 days'],
    [9,4,'The South African TRC had flaws but it demonstrated the power of public testimony.','-3 days'],
    [10,2,'Environmental racism is real and it needs legal remedies.','-1 day'],
    [11,3,'Mentorship programs like Big Brothers Big Sisters have solid evidence behind them.','-4 days'],
    [12,3,'Digital rights advocacy needs to reach communities most affected by surveillance.','-1 day'],
    [13,4,'Whistleblower laws vary wildly by jurisdiction. We need international standards.','-5 days'],
  ]
  replies.each { |r| db.execute("INSERT INTO forum_replies (thread_id,user_id,content,created_at) VALUES (?,?,?,datetime('now',?))", r) }

  petitions = [
    [2,'Fund Community Legal Aid Centers','Every neighborhood deserves access to free legal assistance. We call on the city council to allocate funding for community legal aid centers in underserved areas.','City Council',500,'open','-10 days'],
    [3,'Mandate Police Body Camera Footage Release','Transparency in policing builds public trust. We demand that body camera footage from critical incidents be released within 72 hours.','Department of Justice',1000,'open','-15 days'],
    [5,'Establish a Civilian Oversight Board','Our community needs independent civilian oversight of law enforcement with subpoena power and diverse representation.',"Mayor's Office",300,'open','-7 days'],
    [4,'Protect Whistleblowers in Government','Government employees who expose waste, fraud, and abuse deserve protection, not retaliation.','State Legislature',200,'open','-20 days'],
    [6,'Implement Peace Education in Public Schools','Every child deserves to learn conflict resolution, empathy, and civic responsibility.','School Board',400,'delivered','-30 days'],
    [2,'End Cash Bail for Non-Violent Offenses','No one should be jailed simply because they cannot afford bail. Cash bail criminalizes poverty.','State Legislature',750,'open','-5 days'],
  ]
  petitions.each { |p| db.execute("INSERT INTO petitions (user_id,title,description,target_entity,goal_signatures,status,created_at) VALUES (?,?,?,?,?,?,datetime('now',?))", p) }

  sigs = [[1,3,'-9 days'],[1,4,'-8 days'],[1,5,'-7 days'],[1,6,'-6 days'],
          [2,2,'-14 days'],[2,4,'-13 days'],[2,5,'-12 days'],[2,6,'-11 days'],
          [3,2,'-6 days'],[3,3,'-5 days'],[3,4,'-4 days'],
          [4,2,'-19 days'],[4,3,'-18 days'],[4,6,'-17 days'],
          [5,2,'-29 days'],[5,3,'-28 days'],[5,4,'-27 days'],[5,5,'-26 days'],
          [6,3,'-4 days'],[6,4,'-3 days'],[6,5,'-2 days'],[6,6,'-1 day']]
  sigs.each { |s| db.execute("INSERT INTO petition_signatures (petition_id,user_id,created_at) VALUES (?,?,datetime('now',?))", s) }

  evts = [
    [2,'Community Peace Walk','Join us for a peaceful march through downtown to raise awareness about community violence prevention.','rally','City Hall Plaza, 100 Main St',0,'2026-09-25T10:00:00','upcoming','-5 days'],
    [3,'Know Your Rights Workshop','A free workshop covering your legal rights during police encounters, housing disputes, and workplace issues.','workshop','Community Center, 45 Oak Ave',0,'2026-09-20T14:00:00','upcoming','-10 days'],
    [4,'Town Hall: Government Transparency','An open forum where citizens can ask questions about government spending and accountability.','town_hall','Public Library Auditorium',0,'2026-10-05T18:00:00','upcoming','-3 days'],
    [5,'Civic Tech Hackathon','A weekend hackathon focused on building open-source tools for government transparency.','workshop','Innovation Hub, 200 Tech Blvd',0,'2026-10-12T09:00:00','upcoming','-2 days'],
    [6,'Webinar: Peace Education Best Practices','An online panel featuring educators discussing peace education in K-12 settings.','webinar',nil,1,'2026-09-18T16:00:00','upcoming','-7 days'],
    [2,'Restorative Justice Circle Training','Learn to facilitate restorative justice circles in your community.','workshop','Faith Community Center',0,'2026-10-20T09:00:00','upcoming','-1 day'],
    [4,'Public Records Access Day','Volunteers help community members file FOIA requests on issues they care about.','other','Civic Engagement Office',0,'2026-09-15T10:00:00','completed','-14 days'],
  ]
  evts.each { |e| db.execute("INSERT INTO events (user_id,title,description,event_type,location,is_virtual,event_date,status,created_at) VALUES (?,?,?,?,?,?,?,?,datetime('now',?))", e) }

  rsvps = [[1,3,'-4 days'],[1,4,'-3 days'],[1,5,'-2 days'],[1,6,'-1 day'],
           [2,2,'-9 days'],[2,5,'-8 days'],[2,6,'-7 days'],
           [3,2,'-2 days'],[3,3,'-1 day'],
           [4,2,'-1 day'],[4,3,'-1 day'],[4,6,'-1 day'],
           [5,2,'-6 days'],[5,3,'-5 days'],[5,4,'-4 days'],
           [6,3,'-1 day'],[6,5,'-1 day']]
  rsvps.each { |r| db.execute("INSERT INTO event_rsvps (event_id,user_id,created_at) VALUES (?,?,datetime('now',?))", r) }

  resources = [
    ['A Guide to Filing Freedom of Information Requests','Step-by-step instructions for requesting government documents under FOIA.','Freedom of Information Act (FOIA) requests are one of the most powerful tools for government transparency.\n\n**Step 1: Identify the Agency**\nDetermine which government agency holds the records you seek.\n\n**Step 2: Write Your Request**\nBe as specific as possible. Include date ranges, document types, and any reference numbers.\n\n**Step 3: Submit and Track**\nMost agencies accept requests online. Keep your confirmation number.','guide','institutions','Priya Sharma','-15 days'],
    ['Community Organizing Toolkit','Practical strategies for building grassroots movements around peace and justice issues.','Effective community organizing starts with listening.\n\n**Build a Core Team**\nFind 5-10 committed people who share your vision.\n\n**Set Achievable Goals**\nStart with a winnable issue to build momentum.\n\n**Use Multiple Tactics**\nCombine direct action with institutional strategies.','toolkit','peace','Maria Santos','-12 days'],
    ['Understanding Your Legal Rights','A comprehensive overview of fundamental legal rights every citizen should know.','Knowing your rights is the first step to protecting them.\n\n**Right to Remain Silent**\nYou are not required to answer questions from law enforcement.\n\n**Right to an Attorney**\nIf arrested, you have the right to legal representation.\n\n**Protection Against Unlawful Search**\nPolice generally need a warrant.','article','justice','James Okoro','-10 days'],
    ["Monitoring Government Spending: A Citizen's Guide",'How to track public expenditures and hold officials accountable.','Public money should serve public interests.\n\n**Use Open Data Portals**\nMany governments publish spending data online.\n\n**Attend Budget Hearings**\nPublic budget hearings are your opportunity to see how funds are allocated.\n\n**File Records Requests**\nIf spending data is not publicly available, file a FOIA request.','guide','institutions','David Chen','-8 days'],
    ['Conflict Resolution for Communities','Evidence-based approaches to resolving community disputes without violence.','Community conflicts are inevitable.\n\n**Mediation**\nA neutral third party helps disputing parties reach a voluntary agreement.\n\n**Restorative Justice Circles**\nBrings together those harmed, those responsible, and the community.\n\n**Dialogue Processes**\nStructured conversations for opposing groups.','toolkit','peace','Amara Diallo','-6 days'],
    ['Digital Rights and Online Freedoms','Understanding and protecting your digital rights in a connected world.','Your rights do not disappear online.\n\n**Data Privacy**\nYou have the right to know what data companies collect.\n\n**Freedom of Expression**\nOnline speech is protected.\n\n**Surveillance Awareness**\nUse encryption tools.','article','human_rights','Priya Sharma','-4 days'],
    ['Building Accountable Institutions: Case Studies','Real-world examples of strengthening institutional accountability.','Accountability does not happen by accident.\n\n**Porto Alegre, Brazil**\nParticipatory budgeting reduced corruption.\n\n**Estonia e-Government**\nDigital governance reduced bribery.\n\n**Malawi Community Scorecards**\nCitizens rated public services.','report','institutions','David Chen','-3 days'],
    ['Advocating for Criminal Justice Reform','A practical guide to pushing for changes in the criminal justice system.','Criminal justice reform requires action at every level.\n\n**Know the Issues**\nMass incarceration and racial disparities need comprehensive solutions.\n\n**Engage Officials**\nWrite letters, attend town halls.\n\n**Vote Locally**\nDistrict attorneys and judges have enormous influence.','guide','justice','James Okoro','-2 days'],
  ]
  resources.each { |r| db.execute("INSERT INTO resources (title,description,content,resource_type,category,author_name,created_at) VALUES (?,?,?,?,?,?,datetime('now',?))", r) }

  puts 'Database seeded with sample data.'
end

# ─── HTTP Server ─────────────────────────────────────────────────────────────

class PeaceVoiceServlet < WEBrick::HTTPServlet::AbstractServlet
  def initialize(server, db)
    super(server)
    @db = db
  end

  def clean_data(obj)
    case obj
    when Hash
      obj.each_with_object({}) do |(k, v), h|
        h[k] = clean_data(v) unless k.is_a?(Integer)
      end
    when Array
      obj.map { |v| clean_data(v) }
    else
      obj
    end
  end

  def json_response(res, data, status = 200)
    res.status = status
    res['Content-Type'] = 'application/json'
    res.body = JSON.generate(clean_data(data))
  end

  def error_response(res, message, status = 400)
    json_response(res, { 'error' => message }, status)
  end

  def read_body(req)
    body = req.body
    return {} unless body && !body.empty?
    JSON.parse(body)
  rescue
    {}
  end

  def session_from_req(req)
    cookie = req.cookies.find { |c| c.name == 'session_id' }
    return nil unless cookie
    get_session(cookie.value)
  end

  def set_session_cookie(res, sid)
    cookie = WEBrick::Cookie.new('session_id', sid)
    cookie.path = '/'
    cookie.max_age = 604800
    cookie.instance_variable_set(:@httponly, true) rescue nil
    res.cookies << cookie
  end

  def clear_session_cookie(res)
    cookie = WEBrick::Cookie.new('session_id', '')
    cookie.path = '/'
    cookie.max_age = 0
    res.cookies << cookie
  end

  def path_parts(path)
    path.split('/').reject(&:empty?)
  end

  # ─── GET ─────────────────────────────────────────────────────────────

  def do_GET(req, res)
    path = req.path
    qs = req.query

    if path.start_with?('/api/')
      handle_api_get(req, res, path, qs)
      return
    end

    # Serve static files
    file_path = path == '/' ? '/index.html' : path
    full_path = File.join(PUBLIC_DIR, file_path)

    if File.file?(full_path)
      serve_file(res, full_path)
      return
    end

    # Try pages dir
    pages_path = File.join(PUBLIC_DIR, 'pages', file_path.sub(/^\//, ''))
    if File.file?(pages_path)
      serve_file(res, pages_path)
      return
    end

    # Fallback to index
    serve_file(res, File.join(PUBLIC_DIR, 'index.html'))
  end

  def serve_file(res, path)
    ext = File.extname(path)
    types = {
      '.html' => 'text/html', '.css' => 'text/css', '.js' => 'application/javascript',
      '.json' => 'application/json', '.png' => 'image/png', '.jpg' => 'image/jpeg',
      '.svg' => 'image/svg+xml', '.ico' => 'image/x-icon'
    }
    res['Content-Type'] = types[ext] || 'application/octet-stream'
    res.body = File.read(path)
  end

  def handle_api_get(req, res, path, qs)
    session = session_from_req(req)
    parts = path_parts(path)

    case
    # GET /api/auth/me
    when path == '/api/auth/me'
      if session
        user = row(@db.execute("SELECT id,username,email,display_name,bio,avatar_color,role,created_at FROM users WHERE id=?", session[:user_id]))
        json_response(res, { 'user' => user })
      else
        json_response(res, { 'user' => nil })
      end

    # GET /api/forums/categories
    when path == '/api/forums/categories'
      cats = @db.execute("SELECT c.*, COUNT(t.id) as thread_count FROM forum_categories c LEFT JOIN forum_threads t ON t.category_id=c.id GROUP BY c.id ORDER BY c.sort_order")
      json_response(res, { 'categories' => cats })

    # GET /api/forums/threads
    when path == '/api/forums/threads'
      cat_id = qs['category_id']
      page = (qs['page'] || 1).to_i
      limit = (qs['limit'] || 20).to_i
      offset = (page - 1) * limit

      where = cat_id ? 'WHERE t.category_id=?' : ''
      params = cat_id ? [cat_id.to_i] : []

      total = @db.execute("SELECT COUNT(*) as c FROM forum_threads t #{where}", params).first['c']
      threads = @db.execute("
        SELECT t.*, u.display_name, u.avatar_color, u.username, c.name as category_name,
               (SELECT COUNT(*) FROM forum_replies WHERE thread_id=t.id) as reply_count
        FROM forum_threads t
        JOIN users u ON u.id=t.user_id
        JOIN forum_categories c ON c.id=t.category_id
        #{where}
        ORDER BY t.is_pinned DESC, t.updated_at DESC
        LIMIT ? OFFSET ?", params + [limit, offset])
      json_response(res, { 'threads' => threads, 'total' => total, 'page' => page, 'totalPages' => [(total.to_f / limit).ceil, 1].max })

    # GET /api/forums/threads/:id
    when path =~ %r{^/api/forums/threads/(\d+)$}
      tid = $1.to_i
      thread = row(@db.execute("SELECT t.*,u.display_name,u.avatar_color,u.username,c.name as category_name FROM forum_threads t JOIN users u ON u.id=t.user_id JOIN forum_categories c ON c.id=t.category_id WHERE t.id=?", tid))
      return error_response(res, 'Thread not found', 404) unless thread
      replies = @db.execute("SELECT r.*,u.display_name,u.avatar_color,u.username FROM forum_replies r JOIN users u ON u.id=r.user_id WHERE r.thread_id=? ORDER BY r.created_at ASC", tid)
      json_response(res, { 'thread' => thread, 'replies' => replies })

    # GET /api/petitions
    when path == '/api/petitions'
      status_filter = qs['status']
      sort = qs['sort'] || 'newest'
      page = (qs['page'] || 1).to_i
      limit = (qs['limit'] || 20).to_i
      offset = (page - 1) * limit

      where = status_filter ? 'WHERE p.status=?' : ''
      params = status_filter ? [status_filter] : []
      order = sort == 'signatures' ? 'signature_count DESC' : 'p.created_at DESC'

      total = @db.execute("SELECT COUNT(*) as c FROM petitions p #{where}", params).first['c']
      petitions = @db.execute("
        SELECT p.*, u.display_name, u.avatar_color,
               (SELECT COUNT(*) FROM petition_signatures WHERE petition_id=p.id) as signature_count
        FROM petitions p JOIN users u ON u.id=p.user_id
        #{where} ORDER BY #{order} LIMIT ? OFFSET ?", params + [limit, offset])
      json_response(res, { 'petitions' => petitions, 'total' => total, 'page' => page, 'totalPages' => [(total.to_f / limit).ceil, 1].max })

    # GET /api/petitions/:id
    when path =~ %r{^/api/petitions/(\d+)$}
      pid = $1.to_i
      petition = row(@db.execute("SELECT p.*,u.display_name,u.avatar_color,u.username,(SELECT COUNT(*) FROM petition_signatures WHERE petition_id=p.id) as signature_count FROM petitions p JOIN users u ON u.id=p.user_id WHERE p.id=?", pid))
      return error_response(res, 'Petition not found', 404) unless petition
      has_signed = false
      if session
        sig = @db.execute("SELECT id FROM petition_signatures WHERE petition_id=? AND user_id=?", [pid, session[:user_id]]).first
        has_signed = !sig.nil?
      end
      signers = @db.execute("SELECT u.display_name,u.avatar_color,ps.created_at FROM petition_signatures ps JOIN users u ON u.id=ps.user_id WHERE ps.petition_id=? ORDER BY ps.created_at DESC LIMIT 20", pid)
      json_response(res, { 'petition' => petition, 'hasSigned' => has_signed, 'recentSigners' => signers })

    # GET /api/events
    when path == '/api/events'
      type_filter = qs['type']
      status_filter = qs['status']
      page = (qs['page'] || 1).to_i
      limit = (qs['limit'] || 20).to_i
      offset = (page - 1) * limit

      conditions = []
      params = []
      conditions << 'e.event_type=?' and params << type_filter if type_filter
      conditions << 'e.status=?' and params << status_filter if status_filter
      where = conditions.empty? ? '' : "WHERE #{conditions.join(' AND ')}"

      total = @db.execute("SELECT COUNT(*) as c FROM events e #{where}", params).first['c']
      events = @db.execute("
        SELECT e.*, u.display_name, u.avatar_color,
               (SELECT COUNT(*) FROM event_rsvps WHERE event_id=e.id) as rsvp_count
        FROM events e JOIN users u ON u.id=e.user_id
        #{where} ORDER BY e.event_date ASC LIMIT ? OFFSET ?", params + [limit, offset])
      json_response(res, { 'events' => events, 'total' => total, 'page' => page, 'totalPages' => [(total.to_f / limit).ceil, 1].max })

    # GET /api/events/:id
    when path =~ %r{^/api/events/(\d+)$}
      eid = $1.to_i
      event = row(@db.execute("SELECT e.*,u.display_name,u.avatar_color,u.username,(SELECT COUNT(*) FROM event_rsvps WHERE event_id=e.id) as rsvp_count FROM events e JOIN users u ON u.id=e.user_id WHERE e.id=?", eid))
      return error_response(res, 'Event not found', 404) unless event
      has_rsvp = false
      if session
        r = @db.execute("SELECT id FROM event_rsvps WHERE event_id=? AND user_id=?", [eid, session[:user_id]]).first
        has_rsvp = !r.nil?
      end
      attendees = @db.execute("SELECT u.display_name,u.avatar_color,r.created_at FROM event_rsvps r JOIN users u ON u.id=r.user_id WHERE r.event_id=? ORDER BY r.created_at ASC", eid)
      json_response(res, { 'event' => event, 'hasRsvp' => has_rsvp, 'attendees' => attendees })

    # GET /api/resources
    when path == '/api/resources'
      type_filter = qs['type']
      cat_filter = qs['category']
      page = (qs['page'] || 1).to_i
      limit = (qs['limit'] || 20).to_i
      offset = (page - 1) * limit

      conditions = []
      params = []
      conditions << 'resource_type=?' and params << type_filter if type_filter
      conditions << 'category=?' and params << cat_filter if cat_filter
      where = conditions.empty? ? '' : "WHERE #{conditions.join(' AND ')}"

      total = @db.execute("SELECT COUNT(*) as c FROM resources #{where}", params).first['c']
      resources = @db.execute("SELECT * FROM resources #{where} ORDER BY created_at DESC LIMIT ? OFFSET ?", params + [limit, offset])
      json_response(res, { 'resources' => resources, 'total' => total, 'page' => page, 'totalPages' => [(total.to_f / limit).ceil, 1].max })

    # GET /api/resources/:id
    when path =~ %r{^/api/resources/(\d+)$}
      rid = $1.to_i
      resource = row(@db.execute("SELECT * FROM resources WHERE id=?", rid))
      return error_response(res, 'Resource not found', 404) unless resource
      json_response(res, { 'resource' => resource })

    # GET /api/users/me/dashboard
    when path == '/api/users/me/dashboard'
      return error_response(res, 'Authentication required', 401) unless session
      uid = session[:user_id]
      threads = @db.execute("SELECT t.*,c.name as category_name,(SELECT COUNT(*) FROM forum_replies WHERE thread_id=t.id) as reply_count FROM forum_threads t JOIN forum_categories c ON c.id=t.category_id WHERE t.user_id=? ORDER BY t.created_at DESC LIMIT 5", uid)
      pc = @db.execute("SELECT p.*,(SELECT COUNT(*) FROM petition_signatures WHERE petition_id=p.id) as signature_count FROM petitions p WHERE p.user_id=? ORDER BY p.created_at DESC LIMIT 5", uid)
      ps = @db.execute("SELECT p.title,p.id,p.status,ps.created_at as signed_at FROM petition_signatures ps JOIN petitions p ON p.id=ps.petition_id WHERE ps.user_id=? ORDER BY ps.created_at DESC LIMIT 5", uid)
      eo = @db.execute("SELECT e.*,(SELECT COUNT(*) FROM event_rsvps WHERE event_id=e.id) as rsvp_count FROM events e WHERE e.user_id=? ORDER BY e.event_date ASC LIMIT 5", uid)
      ea = @db.execute("SELECT e.title,e.id,e.event_date,e.event_type,e.location,r.created_at as rsvped_at FROM event_rsvps r JOIN events e ON e.id=r.event_id WHERE r.user_id=? ORDER BY e.event_date ASC LIMIT 5", uid)
      stats = {
        'totalThreads' => @db.execute("SELECT COUNT(*) as c FROM forum_threads WHERE user_id=?", uid).first['c'],
        'totalReplies' => @db.execute("SELECT COUNT(*) as c FROM forum_replies WHERE user_id=?", uid).first['c'],
        'totalPetitionsCreated' => @db.execute("SELECT COUNT(*) as c FROM petitions WHERE user_id=?", uid).first['c'],
        'totalPetitionsSigned' => @db.execute("SELECT COUNT(*) as c FROM petition_signatures WHERE user_id=?", uid).first['c'],
        'totalEventsOrganized' => @db.execute("SELECT COUNT(*) as c FROM events WHERE user_id=?", uid).first['c'],
        'totalEventsAttending' => @db.execute("SELECT COUNT(*) as c FROM event_rsvps WHERE user_id=?", uid).first['c'],
      }
      json_response(res, { 'threads' => threads, 'petitionsCreated' => pc, 'petitionsSigned' => ps, 'eventsOrganized' => eo, 'eventsAttending' => ea, 'stats' => stats })

    # GET /api/users/:id
    when path =~ %r{^/api/users/(\d+)$}
      uid = $1.to_i
      user = row(@db.execute("SELECT id,username,display_name,bio,avatar_color,created_at FROM users WHERE id=?", uid))
      return error_response(res, 'User not found', 404) unless user
      tc = @db.execute("SELECT COUNT(*) as c FROM forum_threads WHERE user_id=?", uid).first['c']
      pc = @db.execute("SELECT COUNT(*) as c FROM petitions WHERE user_id=?", uid).first['c']
      ec = @db.execute("SELECT COUNT(*) as c FROM events WHERE user_id=?", uid).first['c']
      json_response(res, { 'user' => user, 'stats' => { 'threads' => tc, 'petitions' => pc, 'events' => ec } })

    # GET /api/admin/stats
    when path == '/api/admin/stats'
      return error_response(res, 'Admin access required', 403) unless session && session[:role] == 'admin'
      stats = {}
      %w[users threads replies petitions signatures events rsvps resources].each do |t|
        tbl = t == 'rsvps' ? 'event_rsvps' : (t == 'signatures' ? 'petition_signatures' : t == 'replies' ? 'forum_replies' : (t == 'threads' ? 'forum_threads' : t))
        stats[t] = @db.execute("SELECT COUNT(*) as c FROM #{tbl}").first['c']
      end
      json_response(res, stats)

    # GET /api/admin/users
    when path == '/api/admin/users'
      return error_response(res, 'Admin access required', 403) unless session && session[:role] == 'admin'
      users = @db.execute("SELECT id,username,email,display_name,avatar_color,role,created_at FROM users ORDER BY created_at DESC")
      json_response(res, { 'users' => users })

    # GET /api/stats
    when path == '/api/stats'
      stats = {
        'users' => @db.execute("SELECT COUNT(*) as c FROM users").first['c'],
        'threads' => @db.execute("SELECT COUNT(*) as c FROM forum_threads").first['c'],
        'petitions' => @db.execute("SELECT COUNT(*) as c FROM petitions WHERE status='open'").first['c'],
        'events' => @db.execute("SELECT COUNT(*) as c FROM events WHERE status='upcoming'").first['c'],
        'signatures' => @db.execute("SELECT COUNT(*) as c FROM petition_signatures").first['c'],
      }
      fp = @db.execute("SELECT p.*,u.display_name,(SELECT COUNT(*) FROM petition_signatures WHERE petition_id=p.id) as signature_count FROM petitions p JOIN users u ON u.id=p.user_id WHERE p.status='open' ORDER BY signature_count DESC LIMIT 3")
      ue = @db.execute("SELECT e.*,u.display_name,(SELECT COUNT(*) FROM event_rsvps WHERE event_id=e.id) as rsvp_count FROM events e JOIN users u ON u.id=e.user_id WHERE e.status='upcoming' ORDER BY e.event_date ASC LIMIT 3")
      rt = @db.execute("SELECT t.*,u.display_name,u.avatar_color,c.name as category_name,(SELECT COUNT(*) FROM forum_replies WHERE thread_id=t.id) as reply_count FROM forum_threads t JOIN users u ON u.id=t.user_id JOIN forum_categories c ON c.id=t.category_id ORDER BY t.updated_at DESC LIMIT 3")
      json_response(res, { 'stats' => stats, 'featuredPetitions' => fp, 'upcomingEvents' => ue, 'recentThreads' => rt })

    else
      res.status = 404
      json_response(res, { 'error' => 'Not found' }, 404)
    end
  end

  # ─── POST ────────────────────────────────────────────────────────────

  def do_POST(req, res)
    path = req.path
    return error_response(res, 'Not found', 404) unless path.start_with?('/api/')

    session = session_from_req(req)
    body = read_body(req)
    parts = path_parts(path)

    case
    # POST /api/auth/register
    when path == '/api/auth/register'
      username = (body['username'] || '').strip
      email = (body['email'] || '').strip
      display_name = (body['displayName'] || '').strip
      password = body['password'] || ''
      return error_response(res, 'All fields are required') if [username, email, display_name, password].any?(&:empty?)
      return error_response(res, 'Password must be at least 6 characters') if password.length < 6
      existing = @db.execute("SELECT id FROM users WHERE username=? OR email=?", [username, email]).first
      return error_response(res, 'Username or email already taken') if existing
      colors = ['#3B82F6','#059669','#F59E0B','#EF4444','#8B5CF6','#EC4899']
      color = colors.sample
      pw = hash_password(password)
      @db.execute("INSERT INTO users (username,email,password_hash,display_name,avatar_color) VALUES (?,?,?,?,?)", [username, email, pw, display_name, color])
      uid = @db.last_insert_row_id
      sid = create_session(uid, 'user')
      set_session_cookie(res, sid)
      user = row(@db.execute("SELECT id,username,email,display_name,bio,avatar_color,role FROM users WHERE id=?", uid))
      json_response(res, { 'user' => user })

    # POST /api/auth/login
    when path == '/api/auth/login'
      username = (body['username'] || '').strip
      password = body['password'] || ''
      return error_response(res, 'Username and password are required') if username.empty? || password.empty?
      user = row(@db.execute("SELECT * FROM users WHERE username=? OR email=?", [username, username]))
      return error_response(res, 'Invalid credentials', 401) unless user && verify_password(password, user['password_hash'])
      sid = create_session(user['id'], user['role'])
      set_session_cookie(res, sid)
      user.delete('password_hash')
      json_response(res, { 'user' => user })

    # POST /api/auth/logout
    when path == '/api/auth/logout'
      cookie = req.cookies.find { |c| c.name == 'session_id' }
      $sessions.delete(cookie.value) if cookie && $sessions[cookie.value]
      clear_session_cookie(res)
      json_response(res, { 'success' => true })

    # POST /api/forums/threads
    when path == '/api/forums/threads'
      return error_response(res, 'Authentication required', 401) unless session
      cat_id = body['category_id']
      title = (body['title'] || '').strip
      content = (body['content'] || '').strip
      return error_response(res, 'All fields are required') if [cat_id, title, content].any? { |v| v.nil? || v.to_s.empty? }
      @db.execute("INSERT INTO forum_threads (category_id,user_id,title,content) VALUES (?,?,?,?)", [cat_id.to_i, session[:user_id], title, content])
      tid = @db.last_insert_row_id
      thread = row(@db.execute("SELECT * FROM forum_threads WHERE id=?", tid))
      json_response(res, { 'thread' => thread })

    # POST /api/forums/threads/:id/replies
    when path =~ %r{^/api/forums/threads/(\d+)/replies$}
      return error_response(res, 'Authentication required', 401) unless session
      tid = $1.to_i
      content = (body['content'] || '').strip
      return error_response(res, 'Reply content is required') if content.empty?
      thread = row(@db.execute("SELECT id,is_locked FROM forum_threads WHERE id=?", tid))
      return error_response(res, 'Thread not found', 404) unless thread
      return error_response(res, 'Thread is locked', 403) if thread['is_locked'] == 1
      @db.execute("INSERT INTO forum_replies (thread_id,user_id,content) VALUES (?,?,?)", [tid, session[:user_id], content])
      @db.execute("UPDATE forum_threads SET updated_at=datetime('now') WHERE id=?", tid)
      rid = @db.last_insert_row_id
      reply = row(@db.execute("SELECT r.*,u.display_name,u.avatar_color,u.username FROM forum_replies r JOIN users u ON u.id=r.user_id WHERE r.id=?", rid))
      json_response(res, { 'reply' => reply })

    # POST /api/petitions
    when path == '/api/petitions'
      return error_response(res, 'Authentication required', 401) unless session
      title = (body['title'] || '').strip
      description = (body['description'] || '').strip
      return error_response(res, 'Title and description are required') if title.empty? || description.empty?
      @db.execute("INSERT INTO petitions (user_id,title,description,target_entity,goal_signatures) VALUES (?,?,?,?,?)",
                  [session[:user_id], title, description, body['target_entity'] || '', body['goal_signatures'] || 100])
      pid = @db.last_insert_row_id
      petition = row(@db.execute("SELECT * FROM petitions WHERE id=?", pid))
      json_response(res, { 'petition' => petition })

    # POST /api/petitions/:id/sign
    when path =~ %r{^/api/petitions/(\d+)/sign$}
      return error_response(res, 'Authentication required', 401) unless session
      pid = $1.to_i
      petition = row(@db.execute("SELECT id,status FROM petitions WHERE id=?", pid))
      return error_response(res, 'Petition not found', 404) unless petition
      return error_response(res, 'Petition is no longer open') unless petition['status'] == 'open'
      existing = @db.execute("SELECT id FROM petition_signatures WHERE petition_id=? AND user_id=?", [pid, session[:user_id]]).first
      return error_response(res, 'You have already signed this petition') if existing
      @db.execute("INSERT INTO petition_signatures (petition_id,user_id) VALUES (?,?)", [pid, session[:user_id]])
      count = @db.execute("SELECT COUNT(*) as c FROM petition_signatures WHERE petition_id=?", pid).first['c']
      json_response(res, { 'signed' => true, 'signatureCount' => count })

    # POST /api/events
    when path == '/api/events'
      return error_response(res, 'Authentication required', 401) unless session
      title = (body['title'] || '').strip
      description = (body['description'] || '').strip
      event_date = (body['event_date'] || '').strip
      return error_response(res, 'Title, description, and date are required') if [title, description, event_date].any?(&:empty?)
      @db.execute("INSERT INTO events (user_id,title,description,event_type,location,is_virtual,virtual_link,event_date,max_attendees) VALUES (?,?,?,?,?,?,?,?,?)",
                  [session[:user_id], title, description,
                  body['event_type'] || 'other', body['location'] || '',
                  body['is_virtual'] ? 1 : 0,
                  body['virtual_link'] || '', event_date, body['max_attendees'] || 0])
      eid = @db.last_insert_row_id
      event = row(@db.execute("SELECT * FROM events WHERE id=?", eid))
      json_response(res, { 'event' => event })

    # POST /api/events/:id/rsvp
    when path =~ %r{^/api/events/(\d+)/rsvp$}
      return error_response(res, 'Authentication required', 401) unless session
      eid = $1.to_i
      event = row(@db.execute("SELECT id FROM events WHERE id=?", eid))
      return error_response(res, 'Event not found', 404) unless event
      existing = @db.execute("SELECT id FROM event_rsvps WHERE event_id=? AND user_id=?", [eid, session[:user_id]]).first
      return error_response(res, 'You have already RSVPed') if existing
      @db.execute("INSERT INTO event_rsvps (event_id,user_id) VALUES (?,?)", [eid, session[:user_id]])
      count = @db.execute("SELECT COUNT(*) as c FROM event_rsvps WHERE event_id=?", eid).first['c']
      json_response(res, { 'rsvped' => true, 'rsvpCount' => count })

    else
      error_response(res, 'Not found', 404)
    end
  end

  # ─── PUT ─────────────────────────────────────────────────────────────

  def do_PUT(req, res)
    path = req.path
    return error_response(res, 'Not found', 404) unless path.start_with?('/api/')

    session = session_from_req(req)
    body = read_body(req)

    case
    when path == '/api/users/me'
      return error_response(res, 'Authentication required', 401) unless session
      dn = body['display_name']
      bio = body['bio']
      @db.execute("UPDATE users SET display_name=? WHERE id=?", [dn, session[:user_id]]) if dn
      @db.execute("UPDATE users SET bio=? WHERE id=?", [bio, session[:user_id]]) unless bio.nil?
      user = row(@db.execute("SELECT id,username,email,display_name,bio,avatar_color,role FROM users WHERE id=?", session[:user_id]))
      json_response(res, { 'user' => user })

    when path =~ %r{^/api/admin/users/(\d+)/role$}
      return error_response(res, 'Admin access required', 403) unless session && session[:role] == 'admin'
      uid = $1.to_i
      role = body['role']
      return error_response(res, 'Invalid role') unless %w[user admin].include?(role)
      @db.execute("UPDATE users SET role=? WHERE id=?", [role, uid])
      json_response(res, { 'success' => true })

    when path =~ %r{^/api/admin/petitions/(\d+)/status$}
      return error_response(res, 'Admin access required', 403) unless session && session[:role] == 'admin'
      pid = $1.to_i
      status = body['status']
      return error_response(res, 'Invalid status') unless %w[open closed delivered].include?(status)
      @db.execute("UPDATE petitions SET status=? WHERE id=?", [status, pid])
      json_response(res, { 'success' => true })

    else
      error_response(res, 'Not found', 404)
    end
  end

  # ─── DELETE ──────────────────────────────────────────────────────────

  def do_DELETE(req, res)
    path = req.path
    return error_response(res, 'Not found', 404) unless path.start_with?('/api/')

    session = session_from_req(req)

    case
    when path =~ %r{^/api/petitions/(\d+)/sign$}
      return error_response(res, 'Authentication required', 401) unless session
      pid = $1.to_i
      @db.execute("DELETE FROM petition_signatures WHERE petition_id=? AND user_id=?", [pid, session[:user_id]])
      count = @db.execute("SELECT COUNT(*) as c FROM petition_signatures WHERE petition_id=?", pid).first['c']
      json_response(res, { 'signed' => false, 'signatureCount' => count })

    when path =~ %r{^/api/events/(\d+)/rsvp$}
      return error_response(res, 'Authentication required', 401) unless session
      eid = $1.to_i
      @db.execute("DELETE FROM event_rsvps WHERE event_id=? AND user_id=?", [eid, session[:user_id]])
      count = @db.execute("SELECT COUNT(*) as c FROM event_rsvps WHERE event_id=?", eid).first['c']
      json_response(res, { 'rsvped' => false, 'rsvpCount' => count })

    when path =~ %r{^/api/admin/threads/(\d+)$}
      return error_response(res, 'Admin access required', 403) unless session && session[:role] == 'admin'
      @db.execute("DELETE FROM forum_threads WHERE id=?", $1.to_i)
      json_response(res, { 'success' => true })

    when path =~ %r{^/api/admin/replies/(\d+)$}
      return error_response(res, 'Admin access required', 403) unless session && session[:role] == 'admin'
      @db.execute("DELETE FROM forum_replies WHERE id=?", $1.to_i)
      json_response(res, { 'success' => true })

    when path =~ %r{^/api/admin/petitions/(\d+)$}
      return error_response(res, 'Admin access required', 403) unless session && session[:role] == 'admin'
      @db.execute("DELETE FROM petitions WHERE id=?", $1.to_i)
      json_response(res, { 'success' => true })

    when path =~ %r{^/api/admin/events/(\d+)$}
      return error_response(res, 'Admin access required', 403) unless session && session[:role] == 'admin'
      @db.execute("DELETE FROM events WHERE id=?", $1.to_i)
      json_response(res, { 'success' => true })

    else
      error_response(res, 'Not found', 404)
    end
  end
end

# ─── Start Server ────────────────────────────────────────────────────────────

db = init_db

server = WEBrick::HTTPServer.new(
  Port: PORT,
  BindAddress: '0.0.0.0',
  DocumentRoot: PUBLIC_DIR,
  AccessLog: [],
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::INFO)
)

server.mount '/', PeaceVoiceServlet, db

trap('INT') { server.shutdown }

puts "PeaceVoice server running at http://localhost:#{PORT}"
server.start
