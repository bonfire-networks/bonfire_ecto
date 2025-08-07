# Bonfire.Ecto Usage Rules

Bonfire.Ecto provides structured database transaction management for Bonfire.Epics workflows. It enables atomic database operations with automatic rollback on failure. These rules ensure correct and efficient database handling.

## Core Concepts

### Transaction Management in Epics

Database operations in Epics follow a three-act pattern:

```elixir
epic = %Bonfire.Epics.Epic{
  acts: [
    # Preparation acts queue work
    MyApp.Acts.PrepareDataAct,
    
    # Transaction boundary start
    {Bonfire.Ecto.Acts.Begin, []},
    
    # Execute queued database operations
    {Bonfire.Ecto.Acts.Work, []},
    
    # More acts that need transaction
    MyApp.Acts.UpdateRelatedAct,
    
    # Transaction boundary end
    {Bonfire.Ecto.Acts.Commit, []}
  ]
}
```

### Work Queue Pattern

Acts queue database operations for atomic execution:

```elixir
defmodule MyApp.Acts.CreateUserAct do
  use Bonfire.Epics.Act
  import Bonfire.Ecto
  
  @impl true
  def run(epic, act) do
    changeset = User.changeset(%User{}, epic.assigns.attrs)
    
    # Queue the changeset for insertion
    epic = add(epic, :user, changeset, action: :insert)
    
    {:ok, epic}
  end
end
```

## Transaction Acts

### Begin Act

Opens a database transaction and executes all acts until Commit:

```elixir
# Basic usage
{Bonfire.Ecto.Acts.Begin, []}

# The Begin act:
# - Checks if transaction is needed (skips if errors exist)
# - Opens transaction with repo().transact_with/1
# - Executes all acts between Begin and Commit
# - Rolls back on any error
```

### Work Act

Processes queued database operations:

```elixir
# Executes all queued changesets
{Bonfire.Ecto.Acts.Work, []}

# Supports actions:
# - :insert - Create new records
# - :update - Update existing records
# - :upsert - Insert or update
# - :delete - Delete records
```

### Commit Act

Marks transaction boundary end:

```elixir
# Must be paired with Begin
{Bonfire.Ecto.Acts.Commit, []}

# Note: Commit doesn't execute - it's a boundary marker
# Actual commit happens when Begin act completes successfully
```

### Delete Act

Specialized deletion with association handling:

```elixir
# Delete with cascade support
{Bonfire.Ecto.Acts.Delete, on: :post}

# In preparation act:
epic = Epic.assign(epic, :post, post_to_delete)
```

## Queueing Database Operations

### Adding Changesets

Use the `add/4` function to queue operations:

```elixir
defmodule MyApp.Acts.CreatePostAct do
  use Bonfire.Epics.Act
  import Bonfire.Ecto
  
  @impl true
  def run(epic, act) do
    attrs = epic.assigns.attrs
    user = epic.assigns.current_user
    
    # Create changeset
    changeset = 
      %Post{}
      |> Post.changeset(attrs)
      |> Ecto.Changeset.put_assoc(:creator, user)
    
    # Queue for insertion
    epic = add(epic, :post, changeset, action: :insert)
    
    # Queue related records
    if attrs[:tags] do
      tag_changesets = Enum.map(attrs.tags, &Tag.changeset/1)
      epic = Enum.reduce(tag_changesets, epic, fn cs, epic ->
        add(epic, :tag, cs, action: :insert)
      end)
    end
    
    {:ok, epic}
  end
end
```

### Updating Records

Queue updates with existing structs:

```elixir
defmodule MyApp.Acts.UpdateProfileAct do
  use Bonfire.Epics.Act
  import Bonfire.Ecto
  
  @impl true
  def run(epic, act) do
    profile = epic.assigns.profile
    attrs = epic.assigns.profile_attrs
    
    changeset = Profile.changeset(profile, attrs)
    epic = add(epic, :profile, changeset, action: :update)
    
    {:ok, epic}
  end
end
```

### Upsert Operations

Insert or update based on constraints:

```elixir
# Queue upsert with conflict options
changeset = Settings.changeset(%Settings{user_id: user.id}, attrs)

epic = add(epic, :settings, changeset, 
  action: :upsert,
  on_conflict: :replace_all,
  conflict_target: [:user_id]
)
```

### Direct Deletion

Delete without changeset:

```elixir
defmodule MyApp.Acts.CleanupAct do
  use Bonfire.Epics.Act
  import Bonfire.Ecto
  
  @impl true
  def run(epic, act) do
    # Queue struct for deletion
    epic = maybe_delete(epic, epic.assigns.deprecated_record)
    
    # Or with changeset
    changeset = Ecto.Changeset.change(record)
    epic = add(epic, :cleanup, changeset, action: :delete)
    
    {:ok, epic}
  end
end
```

## Error Handling

### Validation Errors

Changeset errors are automatically promoted to epic errors:

```elixir
# In Work act, validation errors become:
%{
  epic: :ecto,
  act: :work,
  key: key,
  changeset: changeset,
  action: action,
  errors: changeset.errors
}
```

### Transaction Rollback

Any error triggers automatic rollback:

```elixir
epic = %Bonfire.Epics.Epic{
  acts: [
    PrepareAct,
    {Bonfire.Ecto.Acts.Begin, []},
    {Bonfire.Ecto.Acts.Work, []},  # If this fails...
    UpdateRelatedAct,               # This won't execute
    {Bonfire.Ecto.Acts.Commit, []}
  ]
}

# On error, database is unchanged
```

### Error Recovery

Handle specific database errors:

```elixir
defmodule MyApp.Acts.SafeCreateAct do
  use Bonfire.Epics.Act
  import Bonfire.Ecto
  
  @impl true
  def run(epic, act) do
    changeset = Resource.changeset(%Resource{}, epic.assigns.attrs)
    
    # Check for potential conflicts
    if Resource.exists?(name: changeset.changes.name) do
      # Skip creation, use existing
      existing = Resource.get_by(name: changeset.changes.name)
      {:ok, Epic.assign(epic, :resource, existing)}
    else
      # Queue for creation
      epic = add(epic, :resource, changeset, action: :insert)
      {:ok, epic}
    end
  end
end
```

## Complete Epic Patterns

### CRUD Operations

```elixir
# Create epic
config :my_app, :epics,
  create_article: [
    MyApp.Acts.ValidateArticleAct,
    MyApp.Acts.PrepareArticleAct,
    {Bonfire.Ecto.Acts.Begin, []},
    {Bonfire.Ecto.Acts.Work, []},
    MyApp.Acts.CreateTagsAct,
    {Bonfire.Ecto.Acts.Work, []},
    {Bonfire.Ecto.Acts.Commit, []},
    MyApp.Acts.IndexArticleAct,
    MyApp.Acts.NotifyAct
  ]

# Update epic
config :my_app, :epics,
  update_article: [
    MyApp.Acts.LoadArticleAct,
    MyApp.Acts.AuthorizeAct,
    MyApp.Acts.PrepareUpdateAct,
    {Bonfire.Ecto.Acts.Begin, []},
    {Bonfire.Ecto.Acts.Work, []},
    {Bonfire.Ecto.Acts.Commit, []},
    MyApp.Acts.ReindexAct
  ]

# Delete epic  
config :my_app, :epics,
  delete_article: [
    MyApp.Acts.LoadArticleAct,
    MyApp.Acts.AuthorizeAct,
    {Bonfire.Ecto.Acts.Begin, []},
    {Bonfire.Ecto.Acts.Delete, on: :article},
    {Bonfire.Ecto.Acts.Commit, []},
    MyApp.Acts.CleanupIndexAct
  ]
```

### Multi-Model Transactions

```elixir
defmodule MyApp.Acts.CreateOrderAct do
  use Bonfire.Epics.Act
  import Bonfire.Ecto
  
  @impl true
  def run(epic, act) do
    # Queue multiple related operations
    epic
    |> add(:order, order_changeset(), action: :insert)
    |> add_line_items(epic.assigns.items)
    |> add(:inventory_adjustment, adjustment_changeset(), action: :update)
    |> add(:payment, payment_changeset(), action: :insert)
    |> then(&{:ok, &1})
  end
  
  defp add_line_items(epic, items) do
    Enum.reduce(items, epic, fn item, epic ->
      add(epic, {:line_item, item.id}, line_item_changeset(item), action: :insert)
    end)
  end
end
```

### Conditional Transactions

```elixir
# Only use transaction if needed
config :my_app, :epics,
  maybe_update: [
    MyApp.Acts.CheckIfUpdateNeededAct,
    # These acts only run if update needed
    {Bonfire.Ecto.Acts.Begin, []},
    MyApp.Acts.UpdateIfNeededAct,
    {Bonfire.Ecto.Acts.Work, []},
    {Bonfire.Ecto.Acts.Commit, []}
  ]
```

## Testing Database Acts

### Unit Testing Acts

```elixir
defmodule MyApp.Acts.CreateResourceActTest do
  use MyApp.DataCase
  alias Bonfire.Epics.Epic
  import Bonfire.Ecto
  
  test "queues resource for creation" do
    epic = %Epic{assigns: %{attrs: %{name: "Test"}}}
    
    {:ok, result} = MyApp.Acts.CreateResourceAct.run(epic, %{})
    
    # Check work was queued
    assert get_in(result.assigns, [:ecto, :work, :resource])
    assert get_in(result.assigns, [:ecto, :actions, :resource]) == :insert
  end
end
```

### Integration Testing

```elixir
test "complete creation flow" do
  epic = Bonfire.Epics.from_config!(:create_article)
  
  assigns = %{
    current_user: user,
    attrs: %{
      title: "Test Article",
      body: "Content",
      tags: ["elixir", "testing"]
    }
  }
  
  assert {:ok, result} = Bonfire.Epics.run(epic, assigns)
  
  # Verify database state
  article = result.assigns.article
  assert article.id
  assert article.title == "Test Article"
  assert length(article.tags) == 2
  
  # Verify in database
  assert Repo.get(Article, article.id)
end
```

### Testing Rollback

```elixir
test "rolls back on error" do
  epic = %Epic{
    acts: [
      {Bonfire.Ecto.Acts.Begin, []},
      CreateValidAct,
      CreateInvalidAct,  # This will fail
      {Bonfire.Ecto.Acts.Commit, []}
    ]
  }
  
  count_before = Repo.aggregate(Resource, :count)
  
  assert {:error, result} = Bonfire.Epics.run(epic, %{})
  
  # Nothing committed
  assert Repo.aggregate(Resource, :count) == count_before
  assert result.errors != []
end
```

## Performance Optimization

### Transaction Scope

Keep transactions as small as possible:

```elixir
# Good: Minimal transaction scope
config :my_app, :epics,
  process_upload: [
    ValidateFileAct,      # Outside transaction
    ProcessFileAct,       # CPU intensive - outside
    {Bonfire.Ecto.Acts.Begin, []},
    SaveMetadataAct,      # Quick DB writes only
    {Bonfire.Ecto.Acts.Work, []},
    {Bonfire.Ecto.Acts.Commit, []},
    GenerateThumbnailAct  # Slow - outside transaction
  ]

# Bad: Everything in transaction
config :my_app, :epics,
  process_upload_bad: [
    {Bonfire.Ecto.Acts.Begin, []},
    ValidateFileAct,
    ProcessFileAct,       # Blocks DB connection!
    SaveMetadataAct,
    GenerateThumbnailAct, # Blocks even longer!
    {Bonfire.Ecto.Acts.Work, []},
    {Bonfire.Ecto.Acts.Commit, []}
  ]
```

### Batch Operations

Queue multiple operations efficiently:

```elixir
defmodule MyApp.Acts.BatchCreateAct do
  use Bonfire.Epics.Act
  import Bonfire.Ecto
  
  @impl true
  def run(epic, act) do
    items = epic.assigns.items
    
    # Efficient: Single reduce
    epic = Enum.reduce(items, epic, fn item, epic ->
      changeset = Item.changeset(%Item{}, item)
      add(epic, {:item, item.temp_id}, changeset, action: :insert)
    end)
    
    {:ok, epic}
  end
end
```

### Preloading

Load associations outside transactions when possible:

```elixir
defmodule MyApp.Acts.LoadDataAct do
  use Bonfire.Epics.Act
  
  @impl true
  def run(epic, act) do
    # Preload before transaction
    user = epic.assigns.current_user
    user = Repo.preload(user, [:profile, :settings])
    
    {:ok, Epic.assign(epic, :current_user, user)}
  end
end
```

## Best Practices

### 1. Clear Transaction Boundaries

Always pair Begin and Commit acts:

```elixir
# Good: Clear boundaries
acts: [
  PrepareAct,
  {Bonfire.Ecto.Acts.Begin, []},
  DatabaseAct1,
  DatabaseAct2,
  {Bonfire.Ecto.Acts.Commit, []},
  AfterCommitAct
]

# Bad: Missing Commit
acts: [
  {Bonfire.Ecto.Acts.Begin, []},
  DatabaseAct
  # Where's Commit?
]
```

### 2. Queue Work Before Transaction

Prepare changesets outside transaction:

```elixir
# Good: Prepare then transact
defmodule PrepareAct do
  def run(epic, act) do
    # Validation/preparation
    changeset = complex_validation(epic.assigns.attrs)
    epic = add(epic, :record, changeset, action: :insert)
    {:ok, epic}
  end
end

# Then in epic:
acts: [
  PrepareAct,
  {Bonfire.Ecto.Acts.Begin, []},
  {Bonfire.Ecto.Acts.Work, []},
  {Bonfire.Ecto.Acts.Commit, []}
]
```

### 3. Handle Missing Data

Validate required data exists:

```elixir
def run(%{assigns: %{user: nil}} = epic, act) do
  {:error, Epic.add_error(epic, act: :my_act, error: :user_required)}
end

def run(%{assigns: assigns} = epic, act) when not is_map_key(assigns, :attrs) do
  {:error, Epic.add_error(epic, act: :my_act, error: :attrs_required)}
end

def run(epic, act) do
  # Normal processing
end
```

### 4. Use Meaningful Keys

Queue work with descriptive keys:

```elixir
# Good: Unique, meaningful keys
add(epic, :user_profile, profile_cs, action: :insert)
add(epic, {:line_item, item.id}, item_cs, action: :insert)

# Bad: Generic keys that might conflict
add(epic, :record, changeset1, action: :insert)
add(epic, :record, changeset2, action: :insert) # Overwrites!
```

## Common Anti-Patterns

### ❌ Manual Repo Calls in Acts

```elixir
# Bad: Direct repo call
def run(epic, act) do
  {:ok, record} = Repo.insert(changeset)  # Not in transaction!
  {:ok, epic}
end

# Good: Queue for Work act
def run(epic, act) do
  epic = add(epic, :record, changeset, action: :insert)
  {:ok, epic}
end
```

### ❌ Transaction Within Transaction

```elixir
# Bad: Nested transaction attempt
def run(epic, act) do
  Repo.transaction(fn ->
    # This can deadlock or fail
  end)
end

# Good: Use the epic's transaction
def run(epic, act) do
  epic = add(epic, :record, changeset, action: :insert)
  {:ok, epic}
end
```

### ❌ Side Effects in Transaction

```elixir
# Bad: External calls in transaction
acts: [
  {Bonfire.Ecto.Acts.Begin, []},
  DatabaseAct,
  SendEmailAct,      # Could fail and rollback valid DB work!
  {Bonfire.Ecto.Acts.Commit, []},
]

# Good: Side effects after commit
acts: [
  {Bonfire.Ecto.Acts.Begin, []},
  DatabaseAct,
  {Bonfire.Ecto.Acts.Commit, []},
  SendEmailAct       # After successful commit
]
```

### ❌ Long-Running Operations in Transaction

```elixir
# Bad: Slow operations hold connection
acts: [
  {Bonfire.Ecto.Acts.Begin, []},
  ProcessLargeFileAct,    # Takes 30 seconds!
  {Bonfire.Ecto.Acts.Work, []},
  {Bonfire.Ecto.Acts.Commit, []},
]

# Good: Process outside transaction
acts: [
  ProcessLargeFileAct,    # Do slow work first
  {Bonfire.Ecto.Acts.Begin, []},
  SaveResultsAct,         # Quick DB write
  {Bonfire.Ecto.Acts.Work, []},
  {Bonfire.Ecto.Acts.Commit, []},
]
```

## Debugging

### Enable Query Logging

```elixir
# See all queries in transaction
config :my_app, MyApp.Repo, log: :debug
```

### Inspect Queued Work

```elixir
def run(epic, act) do
  epic = add(epic, :user, changeset, action: :insert)
  
  # Debug queued work
  IO.inspect(epic.assigns[:ecto][:work], label: "Queued work")
  IO.inspect(epic.assigns[:ecto][:actions], label: "Actions")
  
  {:ok, epic}
end
```

### Test Transaction Boundaries

```elixir
# Verify transaction is used
test "uses transaction" do
  Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
    # Run epic
    result = Bonfire.Epics.run(epic, assigns)
    
    # Verify we're in a transaction
    assert Repo.in_transaction?()
  end)
end
```

## Integration with ActRepo

For acts that need repo access:

```elixir
defmodule MyApp.Acts.CustomDatabaseAct do
  use Bonfire.Epics.Act
  use Bonfire.Ecto.ActRepo
  import Bonfire.Ecto
  
  @impl true
  def run(epic, act) do
    # repo() is transaction-aware
    query = from(u in User, where: u.active == true)
    users = repo().all(query)
    
    # Can still queue work
    changesets = Enum.map(users, &update_changeset/1)
    epic = Enum.reduce(changesets, epic, fn cs, epic ->
      add(epic, {:user_update, cs.data.id}, cs, action: :update)
    end)
    
    {:ok, epic}
  end
end
```

## Advanced Patterns

### Optimistic Locking

```elixir
defmodule MyApp.Acts.OptimisticUpdateAct do
  use Bonfire.Epics.Act
  import Bonfire.Ecto
  
  @impl true
  def run(epic, act) do
    record = epic.assigns.record
    
    changeset = 
      record
      |> Ecto.Changeset.change(epic.assigns.changes)
      |> Ecto.Changeset.optimistic_lock(:version)
    
    epic = add(epic, :record, changeset, action: :update)
    {:ok, epic}
  end
end
```

### Conditional Work

```elixir
defmodule MyApp.Acts.ConditionalDatabaseAct do
  use Bonfire.Epics.Act
  import Bonfire.Ecto
  
  @impl true
  def run(epic, act) do
    epic = 
      if should_create?(epic) do
        add(epic, :resource, new_changeset(), action: :insert)
      else
        add(epic, :resource, update_changeset(), action: :update)
      end
    
    {:ok, epic}
  end
end
```