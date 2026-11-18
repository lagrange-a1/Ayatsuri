mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
use flutter_rust_bridge::frb;

#[frb]
#[derive(Debug, Clone)]
pub struct Task {
    pub id: u64,
    pub latency: u64,
}

#[frb(opaque)]
pub struct Scheduler {
    tasks: Vec<Task>,
}

#[frb]
impl Scheduler {
    pub fn new() -> Self {
        Scheduler { tasks: Vec::new() }
    }

    pub fn add_task(&mut self, task: Task) {
        self.tasks.push(task);
    }

    pub fn next_task(&mut self) -> Option<Task> {
        if self.tasks.is_empty() {
            return None;
        }
        let mut min_idx = 0;
        for (i, task) in self.tasks.iter().enumerate() {
            if task.latency < self.tasks[min_idx].latency {
                min_idx = i;
            }
        }
        let task = self.tasks.remove(min_idx);
        Some(task)
    }

    pub fn remove_task(&mut self, id: u64) -> bool {
        if let Some(pos) = self.tasks.iter().position(|t| t.id == id) {
            self.tasks.remove(pos);
            true
        } else {
            false
        }
    }
}

#[frb(start)]
pub fn scheduler_lib_init() {
    // initialization code if needed
}

#[cfg(test)]
mod tests {
    use super::*;

    fn task(id: u64, latency: u64) -> Task {
        Task { id, latency }
    }

    #[test]
    fn add_task_then_next_task_pops_in_latency_order() {
        let mut s = Scheduler::new();
        s.add_task(task(1, 100));
        s.add_task(task(2, 50));
        s.add_task(task(3, 75));

        // next_task is destructive: lowest latency first, then the next one.
        let first = s.next_task().expect("expected a task");
        assert_eq!((first.id, first.latency), (2, 50));
        let second = s.next_task().unwrap();
        assert_eq!((second.id, second.latency), (3, 75));
        let third = s.next_task().unwrap();
        assert_eq!((third.id, third.latency), (1, 100));
        assert!(s.next_task().is_none());
    }

    #[test]
    fn next_task_on_empty_is_none() {
        let mut s = Scheduler::new();
        assert!(s.next_task().is_none());
    }

    #[test]
    fn next_task_breaks_latency_ties_by_first_inserted() {
        let mut s = Scheduler::new();
        s.add_task(task(10, 30));
        s.add_task(task(20, 30));
        s.add_task(task(5, 30));

        // Strict `<` comparison keeps the earliest inserted equal-latency task.
        let first = s.next_task().unwrap();
        assert_eq!(first.id, 10);
        assert_eq!(s.next_task().unwrap().id, 20);
        assert_eq!(s.next_task().unwrap().id, 5);
    }

    #[test]
    fn remove_task_deletes_by_id_and_reports_whether_it_existed() {
        let mut s = Scheduler::new();
        s.add_task(task(1, 10));
        s.add_task(task(2, 20));

        assert!(s.remove_task(1));
        assert!(!s.remove_task(1)); // already gone
        assert!(!s.remove_task(999)); // unknown id

        let next = s.next_task().unwrap();
        assert_eq!(next.id, 2);
        assert!(s.next_task().is_none());
    }
}
