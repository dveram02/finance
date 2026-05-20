<template>
  <header
    class="sticky top-0 bg-surface shadow border-b border-line z-30 transition-all duration-300 w-full "
  >
    <div class="px-6 py-4 max-w-full">
      <div class="flex flex-col md:flex-row md:justify-between md:items-center gap-4">
        <div class="flex items-center space-x-4">
          <!-- Mobile toggle -->
          <button class="p-2 rounded-lg text-tx-muted hover:bg-surface-3 md:hidden"
                  @click="$emit('toggle-mobile')">
            <i class="fas fa-bars text-lg"></i>
          </button>
          <!-- Logo (mobile only) -->
          <div class="flex items-center space-x-3">
            <div class="w-10 h-10 bg-blue-600 rounded-lg flex items-center justify-center text-white md:hidden">
              <i class="fas fa-chart-line text-lg"></i>
            </div>
            <div class="flex flex-col">
              <h1 class="text-2xl font-semibold text-gray-800">Executive Overview</h1>
              <p class="text-sm text-tx-muted">Strategic insights and performance metrics</p>
            </div>
          </div>
        </div>

        <!-- Filters -->
        <div class="flex flex-col sm:flex-row items-center gap-4">
          <div class="flex items-center space-x-2">
            <i class="fas fa-calendar-alt text-tx-subtle"></i>
            <select v-model="model.range" class="text-sm border-line-input rounded-md shadow-sm focus:ring-blue-500 focus:border-blue-500">
              <option value="7">Last 7 days</option>
              <option value="30">Last 30 days</option>
              <option value="90">Last 90 days</option>
              <option value="ytd">Year to Date</option>
            </select>
          </div>
          <div class="flex items-center space-x-2">
            <i class="fas fa-building text-tx-subtle"></i>
            <select v-model="model.department" class="text-sm border-line-input rounded-md shadow-sm focus:ring-blue-500 focus:border-blue-500">
              <option value="all">All Departments</option>
              <!-- Add additional departments here -->
            </select>
          </div>
        </div>
      </div>

      <!-- Timestamp -->
      <div class="mt-4 flex justify-between items-center text-sm text-tx-muted">
        <div class="flex items-center space-x-2">
          <i class="fas fa-clock"></i>
          <span>Last updated: {{ model.lastUpdated }}</span>
          <div class="w-2 h-2 bg-green-500 rounded-full animate-pulse"></div>
        </div>
        <div>Next refresh in {{ model.countdown }} minutes</div>
      </div>
    </div>
  </header>
</template>

<script setup>
defineProps({ model: Object })
defineEmits(['toggle-mobile'])
</script>
